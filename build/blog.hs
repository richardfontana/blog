{-# LANGUAGE DeriveDataTypeable, OverloadedStrings, Arrows #-}
module Main where

import Prelude hiding (id)
import Control.Arrow ((>>>), arr, (&&&), (>>^))
import Control.Category (id)
import Control.Monad (forM_)
import Data.Monoid (mempty, mconcat)
import Data.List (isInfixOf)
import Data.Maybe (isNothing)
import Text.Pandoc (Pandoc, HTMLMathMethod(..), WriterOptions(..), 
                    defaultWriterOptions, ParserState)
import Text.Pandoc.Shared (ObfuscationMethod(..))
import System.Environment (getArgs)
import System.Directory (doesFileExist, doesDirectoryExist, 
                         createDirectoryIfMissing, 
                         renameFile, renameDirectory)
import Data.Time.Clock (utctDay, getCurrentTime)
import Data.Time.Calendar (toGregorian)
import System.Locale (defaultTimeLocale)
import Data.Time.Format (parseTime, formatTime)
import System.FilePath ((</>), joinPath, splitDirectories, 
                        takeDirectory, takeExtension, replaceExtension)
import System.Cmd (rawSystem)
import Data.String.Utils (replace)
import Text.Blaze.Html.Renderer.String (renderHtml)
import Text.Blaze ((!), toValue)
import qualified Text.Blaze.Html5 as H
import qualified Text.Blaze.Html5.Attributes as A
import qualified Data.ByteString.Char8 as B
import qualified Data.Map as M
import Debug.Trace (trace, traceShow)
import System.IO (hFlush, stdout)

-- We override some names from Hakyll so we can use a different post
-- naming convention.
import Hakyll hiding (chronological, renderDateField, renderDateFieldWith, 
                      renderTagsField, renderTagCloud, 
                      relativizeUrlsCompiler, relativizeUrls, withUrls)

import Overrides                -- Overrides of Hakyll functions.
import TikZ                     -- TikZ image rendering.



-- | Number of article teasers displayed per sorted index page.
--
articlesPerIndexPage :: Int
articlesPerIndexPage = 10


-- | Set up deployment command.
--
hakyllConf = defaultHakyllConfiguration {
  deployCommand = 
     "rsync -ave ssh _site/ iross@www.skybluetrades.net:/srv/http/skybluetrades.net"
  }


-- | Main program: adds a "publish" option to copy a draft out to the
-- main posts area.
--
main :: IO ()
main = do
  args <- getArgs
  case args of
    ["publish", p] -> publishDraft p
    _              -> doHakyll 
                   

-- | Main Hakyll processing.
--
doHakyll = hakyllWith hakyllConf $ do
    -- Read templates.
    match "templates/*" $ compile templateCompiler
    
    -- Compress CSS files.
    match "css/*" $ do
      route $ setExtension "css"
      compile sass

    -- Copy JavaScript files.
    match "js/*" $ do
      route idRoute
      compile copyFileCompiler


    -- Compile static pages.
    match staticPagePattern $ do
      route $ gsubRoute "static/" (const "") `composeRoutes` setExtension ".html"
      compile staticCompiler
      
    -- Copy other static content.
    match "static/**" $ do
      route $ gsubRoute "static/" (const "")
      compile copyFileCompiler
      
    -- Copy image files.
    match "images/*" $ do
      route idRoute
      compile copyFileCompiler


    -- Render blog posts.
    match "posts/*/*/*/*.markdown" $ do
      route   $ postsRoute `composeRoutes` setExtension ".html"
      compile $ postCompiler
    match "posts/*/*/*/*/text.markdown" $ do
      route   $ postsRoute `composeRoutes` gsubRoute "text.markdown" (const "index.html")
      compile $ postCompiler


    -- Extract tags from raw Markdown for blog posts: extra "raw"
    -- group is needed to break dependency cycle between page
    -- rendering and tag extraction.
    group "raw" $ do
      match "posts/*/*/*/*.markdown" $ do
        compile $ rawPostCompiler
      match "posts/*/*/*/*/text.markdown" $ do
        compile $ rawPostCompiler
    create "tags" $
      requireAll (inGroup $ Just "raw") (\_ ps -> readTags ps :: Tags String)
    

    -- Copy resource files for blog posts.
    match "posts/*/*/*/*/*" $ do
      route   postsRoute
      compile copyFileCompiler


    -- Generate blog index pages: we need to calculate and pass
    -- through the total number of articles to be able to split them
    -- across the right number of index pages.
    match "index*.html" $ route blogRoute
    metaCompile $ requireAll_ postsPattern
      >>> arr (chunk articlesPerIndexPage . chronological)
      >>^ makeIndexPages
      

    -- Add a tag list compiler for every tag used in blog articles.
    match "tags/*" $ route $ blogRoute `composeRoutes` setExtension ".html"
    metaCompile $ require_ "tags"
      >>^ tagsMap
      >>^ (map (\(t, p) -> (fromCapture "tags/*" t, makeTagList t p)))

    
    -- Import blogroll.
    match "resources/blogroll.html" $ compile getResourceString


    -- Render RSS feed for blog.
    match "rss.xml" $ route idRoute
    create "rss.xml" $
      requireAll_ postsPattern
      >>> arr chronological
      >>> mapCompiler (fixRssResourceUrls (feedRoot feedConfiguration))
      >>> renderRss feedConfiguration
  where
    postsPattern :: Pattern (Page String)
    postsPattern = predicate (\i -> isNothing (identifierGroup i) &&
                                    (matches "posts/*/*/*/*.markdown" i || 
                                     matches "posts/*/*/*/*/text.markdown" i))
    postsRoute = gsubRoute "posts/" (const "blog/posts/")
    blogRoute = customRoute (\i -> "blog" </> toFilePath i)
    staticPagePattern :: Pattern (Page String)
    staticPagePattern = 
      predicate (\i -> let is = splitDirectories $ toFilePath i in
                  length is >= 2 && head is == "static" && 
                  takeExtension (last is) == ".markdown")
                   
fixRssResourceUrls :: String -> Compiler (Page String) (Page String)
fixRssResourceUrls root = 
  (arr $ getField "url" &&& id)
  >>> arr (\(url, p) -> changeField "description" 
                        (fixResourceUrls'' (root ++ takeDirectory url)) p)



-- | Process SCSS or CSS.
--
sass :: Compiler Resource String
sass = getResourceString >>> unixFilter "sass" ["-s", "--scss"]
                         >>^ compressCss


-- | Main post compiler: renders date field, adds tags, page title,
-- extracts teaser, applies templates.  This has to use a slightly
-- lower level approach than calling pageCompiler because it needs to
-- get at the raw Markdown source to pick out TikZ images.
--
postCompiler :: Compiler Resource (Page String)
postCompiler = readPageCompiler 
  >>> processTikZs
  >>> addDefaultFields
  >>> pageReadPandocWith defaultHakyllParserState
  >>> arr (fmap (writePandocWith articleWriterOptions))
  >>> arr (renderDateField "date" "%B %e, %Y" "Date unknown")
  >>> arr (renderDateField "published" "%Y-%m-%dT%H:%M:%SZ" "Date unknown")
  >>> renderTagsField "prettytags" (fromCapture "tags/*")
  >>> addPageTitle >>> addTeaser
  >>> arr (copyBodyToField "description")
  >>> requireA "tags" (setFieldA "tagcloud" renderTagCloud)
  >>> requireA "resources/blogroll.html" (setFieldA "blogroll" renderBlogRoll)
  >>> applyTemplateCompilers ["post", "blog", "default"]
  >>> relativizeUrlsCompiler


-- | Slight bodge for processing tags in blog articles: need to have
-- some sort of representation of the articles to extract tags, which
-- we then build into a tagcloud, but we also want to be able to put
-- this tagcloud on the individual article pages, so if we do this in
-- the obvious way, we get a circular dependency.  This hack breaks
-- that cycle, although not in a very pretty way.
--
rawPostCompiler :: Compiler Resource (Page String)
rawPostCompiler = readPageCompiler 
  >>> addDefaultFields
  >>> addFakeUrl
  >>> arr (renderDateField "date" "%B %e, %Y" "Date unknown")
  >>> arr (renderDateField "published" "%Y-%m-%dT%H:%M:%SZ" "Date unknown")
  >>> renderTagsField "prettytags" (fromCapture "tags/*")
  >>> addPageTitle
    where addFakeUrl :: Compiler (Page String) (Page String)
          addFakeUrl = (arr (getField "path") &&& id)
                       >>> arr (uncurry $ (setField "url") . toUrl . ("/blog" </>) . fixExtension)
          fixExtension :: FilePath -> FilePath
          fixExtension f = case last elems of
            "text.markdown" -> joinPath $ init elems ++ ["index.html"]
            _ -> replaceExtension f ".html"
            where elems = splitDirectories f
  

-- | Static page compiler: renders date field, adds tags, page title,
-- extracts teaser, applies templates.  This has to use a slightly
-- lower level approach than calling pageCompiler because it needs to
-- get at the raw Markdown source to pick out TikZ images.
--
staticCompiler :: Compiler Resource (Page String)
staticCompiler = pageCompiler 
  >>> arr (setField "pagetitle" "Sky Blue Trades")
  >>> applyTemplateCompilers ["default"]
  >>> relativizeUrlsCompiler


-- | Pandoc writer options.
--
articleWriterOptions :: WriterOptions
articleWriterOptions = defaultWriterOptions
    { writerEmailObfuscation = NoObfuscation, 
      writerHTMLMathMethod   = MathML Nothing, 
      writerLiterateHaskell  = True }


-- | Add a page title field.
--
addPageTitle :: Compiler (Page String) (Page String)
addPageTitle = (arr (getField "title") &&& id)
               >>> arr (uncurry $ (setField "pagetitle") . ("Sky Blue Trades | " ++))


-- | Auxiliary compiler: generate a post list from a list of given posts, and
-- add it to the current page under @$posts@.
--
addPostList :: String -> Compiler (Page String, [Page String]) (Page String)
addPostList tmp = setFieldA "posts" $
    arr chronological
        >>> require (parseIdentifier tmp) (\p t -> map (applyTemplate t) p)
        >>> arr mconcat >>> arr pageBody


-- | Auxiliary compiler: set up a tag list page.
--
makeTagList :: String -> [Page String] -> Compiler () (Page String)
makeTagList tag posts =
    constA (mempty, posts)
        >>> addPostList "templates/tagitem.html"
        >>> arr (setField "title" ("Posts tagged &#8216;" ++ tag ++ "&#8217;"))
        >>> arr (setField "pagetitle" 
                 ("Sky Blue Trades | Tagged &#8216;" ++ tag ++ "&#8217;"))
        >>> requireA "tags" (setFieldA "tagcloud" renderTagCloud)
        >>> requireA "resources/blogroll.html" (setFieldA "blogroll" renderBlogRoll)
        >>> applyTemplateCompilers ["tags", "blog", "default"]
        >>> relativizeUrlsCompiler


-- | Helper function to fix up link categories in blogroll.
--
renderBlogRoll :: Compiler String String
renderBlogRoll = arr (replace "<a" "<a class=\"blogrolllink\"" . 
                      replace "<div" "<div class=\"blogrollcategory\"")


-- | Helper function for index page metacompilation: generate
-- appropriate number of index pages with correct names and the
-- appropriate posts on each one.
--
makeIndexPages :: [[Page String]] -> 
                  [(Identifier (Page String), Compiler () (Page String))]
makeIndexPages ps = map doOne (zip [1..] ps)
  where doOne (n, ps) = (indexIdentifier n, makeIndexPage n maxn ps)
        maxn = nposts `div` articlesPerIndexPage +
               if (nposts `mod` articlesPerIndexPage /= 0) then 1 else 0
        nposts = sum $ map length ps
        indexIdentifier n = parseIdentifier url
          where url = "index" ++ (if (n == 1) then "" else show n) ++ ".html" 


-- | Make a single index page: inserts posts, sets up navigation links
-- to older and newer article index pages, applies templates.
--
makeIndexPage :: Int -> Int -> [Page String] -> Compiler () (Page String)
makeIndexPage n maxn posts = 
  constA (mempty, posts)
  >>> addPostList "templates/postitem.html"
  >>> arr (setField "navlinkolder" (indexNavLink n 1 maxn))
  >>> arr (setField "navlinknewer" (indexNavLink n (-1) maxn))
  >>> arr (setField "pagetitle" "Sky Blue Trades")
  >>> requireA "tags" (setFieldA "tagcloud" renderTagCloud)
  >>> requireA "resources/blogroll.html" (setFieldA "blogroll" renderBlogRoll)
  >>> applyTemplateCompilers ["posts", "index", "blog", "default"]
  >>> relativizeUrlsCompiler


-- | Generate navigation link HTML for stepping between index pages.
--
indexNavLink :: Int -> Int -> Int -> String
indexNavLink n d maxn = renderHtml ref
  where ref = if (refPage == "") then ""
              else H.a ! A.href (toValue $ toUrl $ refPage) $ 
                   (H.preEscapedToMarkup lab)
        lab :: String
        lab = if (d > 0) then "&laquo; OLDER POSTS" else "NEWER POSTS &raquo;"
        refPage = if (n + d < 1 || n + d > maxn) then ""
                  else case (n + d) of
                    1 -> "blog/index.html"
                    _ -> "blog/index" ++ (show $ n + d) ++ ".html"
  

-- | RSS feed configuration.
--
feedConfiguration :: FeedConfiguration
feedConfiguration = FeedConfiguration
    { feedTitle       = "Sky Blue Trades RSS feed."
    , feedDescription = "RSS feed for the Sky Blue Trades blog."
    , feedAuthorName  = "Ian Ross"
    , feedAuthorEmail = "ian@skybluetrades.net"
    , feedRoot        = "http://www.skybluetrades.net"
    }


-- | Turns body of the page into the teaser: anything up to the
-- <!--MORE--> mark is the teaser, except for text between the
-- <!--NOTEASERBEGIN--> and <!--NOTEASEREND--> marks (useful for
-- keeping images out of teasers).
--
addTeaser :: Compiler (Page String) (Page String) 
addTeaser = arr (copyBodyToField "teaser")
    >>> arr (changeField "teaser" extractTeaser)
    >>> (arr $ getField "url" &&& id) 
    >>> fixTeaserResourceUrls
    >>> (id &&& arr pageBody)
    >>> arr (\(p, b) -> setField "readmore" 
                        (if (isInfixOf "<!--MORE-->" (pageBody p)) 
                         then (readMoreLink p) else "") p)
      where
        extractTeaser = unlines . (noTeaser . extractTeaser') . lines
        extractTeaser' = takeWhile (/= "<!--MORE-->")
        
        noTeaser [] = []
        noTeaser ("<!--NOTEASERBEGIN-->" : xs) = 
          drop 1 $ dropWhile (/= "<!--NOTEASEREND-->") xs
        noTeaser (x : xs) = x : (noTeaser xs)
        
        readMoreLink :: Page String -> String
        readMoreLink p = renderHtml $ H.div ! A.class_ "readmore" $ 
                         H.a ! A.href (toValue $ getField "url" p) $ 
                         H.preEscapedToMarkup ("Read more &raquo;"::String)
                         
        fixTeaserResourceUrls :: Compiler (String, (Page String)) (Page String)
        fixTeaserResourceUrls = arr $ (\(url, p) -> fixResourceUrls' url p)
          where fixResourceUrls' url p = 
                  changeField "teaser" (fixResourceUrls'' (takeDirectory url)) p


fixResourceUrls'' :: String -> String -> String
fixResourceUrls'' path = withUrls ["src", "href", "data"] 
                         (\x -> if '/' `elem` x then x 
                                else path ++ "/" ++ x)


-- | Publishing a draft:
--
--  1. Determine whether the path to be published exists and whether
--     it's a single file or a directory.
--
--  2. Make sure that the posts/YYYY/MM/DD directory exists for today.
--
--  3. Move the draft article over to the relevant posts
--     sub-directory.
--
--  4. Update the modification time of the moved post to the current
--     time.
--
publishDraft :: String -> IO ()
publishDraft path = do
  fExist <- doesFileExist path
  dExist <- doesDirectoryExist path
  if (not fExist && not dExist) 
    then error $ "Neither file nor directory exists: " ++ path
    else do
      postDir <- todaysPostDir
      createDirectoryIfMissing True postDir
      let postPath = joinPath [postDir, last $ splitDirectories path]
      if fExist 
        then renameFile path postPath
        else do 
        putStrLn (path ++ " -> " ++ postPath)
        renameDirectory path postPath
      err <- rawSystem "touch" [postPath]
      addTimestamp postPath
      putStrLn $ "Published to " ++ postPath


-- | Add a timestamp as metadata for ordering purposes.
--
addTimestamp :: String -> IO ()
addTimestamp postPath = do
  fExist <- doesFileExist postPath
  let modFile = if fExist then postPath else postPath ++ "/text.markdown"
  putStrLn ("Editing " ++ modFile)
  pg <- B.readFile modFile
  t <- getCurrentTime
  let ts = formatTime defaultTimeLocale "%H:%M:%S" t
  B.writeFile modFile $ B.pack $ addTimestamp' (B.unpack pg) ts
    where addTimestamp' pg ts = writePage $ setField "timestamp" ts $ readPage pg
          writePage :: Page String -> String
          writePage pg = "---\n" ++ renderMetadata (pageMetadata pg) ++ 
                         "---\n" ++ (pageBody pg)
          renderMetadata md = unlines $ map (\(k, d) -> k ++ ": " ++ d) $ M.toList md
        

-- | Utility function to generate path to today's posts directory.
--
todaysPostDir :: IO FilePath
todaysPostDir = do
  t <- getCurrentTime
  let (y, m, d) = toGregorian $ utctDay t
  return $ joinPath ["posts", show y, show0 m, show0 d]
  where show0 n = (if n < 10 then "0" else "") ++ show n
  

-- | String together multiple template compilers.
--
applyTemplateCompilers :: [String] -> Compiler (Page String) (Page String)
applyTemplateCompilers [] = arr id
applyTemplateCompilers (c:cs) = applyTemplateCompiler ident >>> 
                                applyTemplateCompilers cs
  where ident = parseIdentifier ("templates/" ++ c ++ ".html")


-- | Split list into equal sized sublists.
--
chunk :: Int -> [a] -> [[a]]
chunk n [] = []
chunk n xs = ys : chunk n zs
  where (ys,zs) = splitAt n xs
