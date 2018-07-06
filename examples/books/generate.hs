{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE TypeOperators     #-}

import           Elm.Derive   (defaultOptions, deriveBoth)

import           Servant.API  ((:>), (:<|>), Capture, Get, ReqBody, Post, JSON)
import           Servant.Elm  (DefineElm (DefineElm), ElmOptions(urlPrefix),
                               Proxy (Proxy), UrlPrefix(Static), defElmImports,
                               defElmOptions, generateElmModuleWith)

data Book = Book
    { name :: String
    }

deriveBoth defaultOptions ''Book

type BooksApi = "books" :> ReqBody '[JSON] Book :> Post '[JSON] Book
           :<|> "books" :> Get '[JSON] [Book]
           :<|> "books" :> Capture "bookId" Int :> Get '[JSON] Book

myElmOpts :: ElmOptions
myElmOpts = defElmOptions { urlPrefix = Static "http://localhost:8000" }

main :: IO ()
main =
  generateElmModuleWith
    defElmOptions
    [ "Generated"
    , "BooksApi"
    ]
    defElmImports
    "elm"
    [ DefineElm (Proxy :: Proxy Book)
    ]
    (Proxy :: Proxy BooksApi)
