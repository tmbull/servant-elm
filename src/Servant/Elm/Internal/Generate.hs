{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
module Servant.Elm.Internal.Generate where

import           Prelude                      hiding ((<$>))
import           Control.Lens                 (to, (^.))
import           Data.List                    (nub)
import           Data.Maybe                   (catMaybes)
import           Data.Proxy                   (Proxy)
import           Data.Text                    (Text)
import qualified Data.Text                    as T
import qualified Data.Text.Lazy               as L
import qualified Data.Text.Encoding           as T
--import           Elm                          (ElmDatatype(..), ElmPrimitive(..))
--import qualified Elm
import           Elm.Module      (DefineElm, defaultAlterations)
--import           Elm.TyRep       (ETypeDef, IsElmDefinition, compileElmDef)
import           Elm.TyRep (EAlias(..), ESum(..), EPrimAlias(..), EType(..), ETypeDef(..), ETypeName(..), ETVar(..), IsElmDefinition(..), SumEncoding'(..), compileElmDef)

import           Servant.API                  (NoContent (..))
import           Servant.Elm.Internal.Foreign (LangElm, getEndpoints)
import           Servant.Elm.Internal.Orphans ()
import qualified Servant.Foreign              as F
import           Text.PrettyPrint.Leijen.Text


-- TODO: Export this stuff from elm-bridge

getName :: ETypeDef -> ETypeName
getName eType = case defaultAlterations eType of
  ETypeAlias (EAlias name _ _ _ _) -> name
  ETypePrimAlias (EPrimAlias name _) -> name
  ETypeSum (ESum name _ _ _ _) -> name


toElmTypeRef :: ETypeDef -> Text
toElmTypeRef eType = T.pack $ et_name $ getName eType

toElmDecoderRef :: ETypeDef -> Text
toElmDecoderRef eType = "jsonDec" `T.append` toElmTypeRef eType

toElmEncoderRef :: ETypeDef -> Text
toElmEncoderRef eType = "jsonEnc" `T.append` toElmTypeRef eType

{-|
Options to configure how code is generated.
-}
data ElmOptions = ElmOptions
  { {- | The protocol, host and any path prefix to be used as the base for all
    requests.

    Example: @Static "https://mydomain.com/api/v1"@

    When @Dynamic@, the generated Elm functions take the base URL as the first
    argument.
    -}
    urlPrefix             :: UrlPrefix
  , elmModuleName         :: String
    -- ^ Options to pass to elm-export
--  , emptyResponseElmTypes :: [DefineElm]
    -- ^ Types that represent an empty Http response.
--  , stringElmTypes        :: [DefineElm]
    -- ^ Types that represent a String.
  }


data UrlPrefix
  = Static T.Text
  | Dynamic


{-|
Default options for generating Elm code.

The default options are:

> { urlPrefix =
>     Static ""
> , elmExportOptions =
>     Elm.defaultOptions
> , emptyResponseElmTypes =
>     [ toElmType NoContent ]
> , stringElmTypes =
>     [ toElmType "" ]
> }
-}
defElmOptions :: ElmOptions
defElmOptions = ElmOptions
  { urlPrefix = Static ""
  , elmModuleName = "MyModule"
  -- , emptyResponseElmTypes =
  --     [ DefineElm (Proxy :: Proxy NoContent)
  --     , DefineElm (Proxy :: Proxy ())
  --     ]
  -- , stringElmTypes =
  --     [ DefineElm (Proxy :: Proxy String)
  --     , DefineElm (Proxy :: Proxy T.Text)
  --     ]
  }


{-|
Default imports required by generated Elm code.

You probably want to include this at the top of your generated Elm module.

The default required imports are:

> import Json.Decode exposing (..)
> import Json.Decode.Pipeline exposing (..)
> import Json.Encode
> import Http
> import String
-}
defElmImports :: Text
defElmImports =
  T.unlines
    [ "import Json.Decode exposing (..)"
    , "import Json.Decode.Pipeline exposing (..)"
    , "import Json.Encode"
    , "import Http"
    , "import String"
    ]


{-|
Generate Elm code for the API with default options.

Returns a list of Elm functions to query your Servant API from Elm.

You could spit these out to a file and call them from your Elm code, but you
would be better off creating a 'Spec' with the result and using 'specsToDir',
which handles the module name for you.
-}
generateElmForAPI
  :: ( F.HasForeign LangElm ETypeDef api
     , F.GenerateList ETypeDef (F.Foreign ETypeDef api))
  => Proxy api
  -> [Text]
generateElmForAPI =
  generateElmForAPIWith defElmOptions


{-|
Generate Elm code for the API with custom options.
-}
generateElmForAPIWith
  :: ( F.HasForeign LangElm ETypeDef api
     , F.GenerateList ETypeDef (F.Foreign ETypeDef api))
  => ElmOptions
  -> Proxy api
  -> [Text]
generateElmForAPIWith opts =
  nub . map docToText . map (generateElmForRequest opts) . getEndpoints

i :: Int
i = 4

{-|
Generate an Elm function for one endpoint.
-}
generateElmForRequest :: ElmOptions -> F.Req ETypeDef -> Doc
generateElmForRequest opts request =
  funcDef
  where
    funcDef =
      vsep
        [ fnName <+> ":" <+> typeSignature
        , fnName <+> args <+> equals
        , case letParams of
            Just params ->
              indent i
              (vsep ["let"
                    , indent i params
                    , "in"
                    , indent i elmRequest
                    ])
            Nothing ->
              indent i elmRequest
        ]

    fnName =
      request ^. F.reqFuncName . to (T.replace "-" "" . F.camelCase) . to stext

    typeSignature =
      mkTypeSignature opts request

    args =
      mkArgs opts request

    letParams =
      mkLetParams opts request

    elmRequest =
      mkRequest opts request

mkTypeSignature :: ElmOptions -> F.Req ETypeDef -> Doc
mkTypeSignature opts request =
  (hsep . punctuate " ->" . concat)
    [ catMaybes [urlPrefixType]
    , headerTypes
    , urlCaptureTypes
    , queryTypes
    , catMaybes [bodyType, returnType]
    ]
  where
    urlPrefixType :: Maybe Doc
    urlPrefixType =
        case (urlPrefix opts) of
          Dynamic -> Just "String"
          Static _ -> Nothing

    elmTypeRef eType =
      stext (toElmTypeRef eType)

    headerTypes :: [Doc]
    headerTypes =
      [ header ^. F.headerArg . F.argType . to elmTypeRef
      | header <- request ^. F.reqHeaders
      , isNotCookie header
      ]

    urlCaptureTypes :: [Doc]
    urlCaptureTypes =
        [ F.captureArg capture ^. F.argType . to elmTypeRef
        | capture <- request ^. F.reqUrl . F.path
        , F.isCapture capture
        ]

    queryTypes :: [Doc]
    queryTypes =
      [ arg ^. F.queryArgName . F.argType . to elmTypeRef
      | arg <- request ^. F.reqUrl . F.queryStr
      ]

    bodyType :: Maybe Doc
    bodyType =
        fmap elmTypeRef $ request ^. F.reqBody

    returnType :: Maybe Doc
    returnType = do
      result <- fmap elmTypeRef $ request ^. F.reqReturnType
      pure ("Http.Request" <+> parens result)


elmHeaderArg :: F.HeaderArg ETypeDef -> Doc
elmHeaderArg header =
  "header_" <>
  header ^. F.headerArg . F.argName . to (stext . T.replace "-" "_" . F.unPathSegment)


elmCaptureArg :: F.Segment ETypeDef -> Doc
elmCaptureArg segment =
  "capture_" <>
  F.captureArg segment ^. F.argName . to (stext . F.unPathSegment)


elmQueryArg :: F.QueryArg ETypeDef -> Doc
elmQueryArg arg =
  "query_" <>
  arg ^. F.queryArgName . F.argName . to (stext . F.unPathSegment)


elmBodyArg :: Doc
elmBodyArg =
  "body"


isNotCookie :: F.HeaderArg f -> Bool
isNotCookie header =
   header
     ^. F.headerArg
      . F.argName
      . to ((/= "cookie") . T.toLower . F.unPathSegment)


mkArgs
  :: ElmOptions
  -> F.Req ETypeDef
  -> Doc
mkArgs opts request =
  (hsep . concat) $
    [ -- Dynamic url prefix
      case urlPrefix opts of
        Dynamic -> ["urlBase"]
        Static _ -> []
    , -- Headers
      [ elmHeaderArg header
      | header <- request ^. F.reqHeaders
      , isNotCookie header
      ]
    , -- URL Captures
      [ elmCaptureArg segment
      | segment <- request ^. F.reqUrl . F.path
      , F.isCapture segment
      ]
    , -- Query params
      [ elmQueryArg arg
      | arg <- request ^. F.reqUrl . F.queryStr
      ]
    , -- Request body
      maybe [] (const [elmBodyArg]) (request ^. F.reqBody)
    ]


mkLetParams :: ElmOptions -> F.Req ETypeDef -> Maybe Doc
mkLetParams opts request =
  if null (request ^. F.reqUrl . F.queryStr) then
    Nothing
  else
    Just $ "params =" <$>
           indent i ("List.filter (not << String.isEmpty)" <$>
                      indent i (elmList params))
  where
    params :: [Doc]
    params = map paramToDoc (request ^. F.reqUrl . F.queryStr)

    paramToDoc :: F.QueryArg ETypeDef -> Doc
    paramToDoc qarg =
      -- something wrong with indentation here...
      case qarg ^. F.queryArgType of
        F.Normal ->
          let
            argType = qarg ^. F.queryArgName . F.argType
            toStringSrc = ""
            wrapped = False
            -- TODO: ????
            -- wrapped = isElmMaybeType argType
            -- -- Don't use "toString" on Elm Strings, otherwise we get extraneous quotes.
            -- toStringSrc =
            --   if isElmStringType opts argType || isElmMaybeStringType opts argType then
            --     ""
            --   else
            --     "toString >> "
          in
              (if wrapped then name else "Just" <+> name) <$>
              indent 4 ("|> Maybe.map" <+> parens (toStringSrc <> "Http.encodeUri >> (++)" <+> dquotes (elmName <> equals)) <$>
                        "|> Maybe.withDefault" <+> dquotes empty)

        F.Flag ->
            "if" <+> name <+> "then" <$>
            indent 4 (dquotes (name <> equals)) <$>
            indent 2 "else" <$>
            indent 4 (dquotes empty)

        F.List ->
            name <$>
            indent 4 ("|> List.map" <+> parens (backslash <> "val ->" <+> dquotes (name <> "[]=") <+> "++ (val |> toString |> Http.encodeUri)") <$>
                      "|> String.join" <+> dquotes "&")
      where
        name = elmQueryArg qarg
        elmName= qarg ^. F.queryArgName . F.argName . to (stext . F.unPathSegment)


mkRequest :: ElmOptions -> F.Req ETypeDef -> Doc
mkRequest opts request =
  "Http.request" <$>
  indent i
    (elmRecord
       [ "method =" <$>
         indent i (dquotes method)
       , "headers =" <$>
         indent i
           (elmListOfMaybes headers)
       , "url =" <$>
         indent i url
       , "body =" <$>
         indent i body
       , "expect =" <$>
         indent i expect
       , "timeout =" <$>
         indent i "Nothing"
       , "withCredentials =" <$>
         indent i "False"
       ])
  where
    method =
       request ^. F.reqMethod . to (stext . T.decodeUtf8)

    mkHeader header =
      let headerName = header ^. F.headerArg . F.argName . to (stext . F.unPathSegment)
          headerArgName = elmHeaderArg header
          argType = header ^. F.headerArg . F.argType
--          wrapped = isElmMaybeType argType
          -- TODO ???
          wrapped = False
          toStringSrc = mempty
          -- toStringSrc =
          --   if isElmMaybeStringType opts argType || isElmStringType opts argType then
          --     mempty
          --   else
          --     " << toString"
      in
        "Maybe.map" <+> parens (("Http.header" <+> dquotes headerName <> toStringSrc))
        <+>
        (if wrapped then headerArgName else parens ("Just" <+> headerArgName))

    headers =
      [ mkHeader header
      | header <- request ^. F.reqHeaders
      , isNotCookie header
      ]

    url =
      mkUrl opts (request ^. F.reqUrl . F.path)
       <> mkQueryParams request

    body =
      case request ^. F.reqBody of
        Nothing ->
          "Http.emptyBody"

        Just elmTypeExpr ->
          let
            encoderName =
              toElmEncoderRef elmTypeExpr
          in
            "Http.jsonBody" <+> parens (stext encoderName <+> elmBodyArg)

    expect =
      case request ^. F.reqReturnType of
        -- TODO: ????
        -- Just elmTypeExpr | isEmptyType opts elmTypeExpr ->
        --   let elmConstructor =
        --         toElmTypeRef elmTypeExpr
        --   in
        --     "Http.expectStringResponse" <$>
        --     indent i (parens (backslash <> braces " body " <+> "->" <$>
        --                       indent i ("if String.isEmpty body then" <$>
        --                                 indent i "Ok" <+> stext elmConstructor <$>
        --                                 "else" <$>
        --                                 indent i ("Err" <+> dquotes "Expected the response body to be empty")) <> line))
        

        Just elmTypeExpr ->
          "Http.expectJson" <+> stext (toElmDecoderRef elmTypeExpr)

        Nothing ->
          error "mkHttpRequest: no reqReturnType?"


mkUrl :: ElmOptions -> [F.Segment ETypeDef] -> Doc
mkUrl opts segments =
  "String.join" <+> dquotes "/" <$>
  (indent i . elmList)
    ( case urlPrefix opts of
        Dynamic -> "urlBase"
        Static url -> dquotes (stext url)
      : map segmentToDoc segments)
  where

    segmentToDoc :: F.Segment ETypeDef -> Doc
    segmentToDoc s =
      case F.unSegment s of
        F.Static path ->
          dquotes (stext (F.unPathSegment path))
        F.Cap arg ->
          let
            -- Don't use "toString" on Elm Strings, otherwise we get extraneous quotes.
            -- TODO: ????
            toStringSrc = empty
            -- toStringSrc =
            --   if isElmStringType opts (arg ^. F.argType) then
            --     empty
            --   else
            --     " |> toString"
          in
            (elmCaptureArg s) <> toStringSrc <> " |> Http.encodeUri"


mkQueryParams
  :: F.Req ETypeDef
  -> Doc
mkQueryParams request =
  if null (request ^. F.reqUrl . F.queryStr) then
    empty
  else
    line <> "++" <+> align ("if List.isEmpty params then" <$>
                            indent i (dquotes empty) <$>
                            "else" <$>
                            indent i (dquotes "?" <+> "++ String.join" <+> dquotes "&" <+> "params"))


-- {- | Determines whether we construct an Elm function that expects an empty
-- response body.
-- -}
-- isEmptyType :: ElmOptions -> ETypeDef -> Bool
-- isEmptyType opts elmTypeExpr =
--   elmTypeExpr `elem` emptyResponseElmTypes opts


-- {- | Determines whether we call `toString` on URL captures and query params of
-- this type in Elm.
-- -}
-- isElmStringType :: ElmOptions -> ETypeDef -> Bool
-- isElmStringType opts elmTypeExpr =
--   elmTypeExpr `elem` stringElmTypes opts

-- {- | Determines whether a type is 'Maybe a' where 'a' is something akin to a 'String'.
-- -}
-- isElmMaybeStringType :: ElmOptions -> ETypeDef -> Bool
-- isElmMaybeStringType opts (ElmPrimitive (EMaybe elmTypeExpr)) = elmTypeExpr `elem` stringElmTypes opts
-- isElmMaybeStringType _ _ = False

-- isElmMaybeType :: ETypeDef -> Bool
-- isElmMaybeType (ElmPrimitive (EMaybe _)) = True
-- isElmMaybeType _ = False


-- Doc helpers


docToText :: Doc -> Text
docToText =
  L.toStrict . displayT . renderPretty 0.4 100

stext :: Text -> Doc
stext = text . L.fromStrict

elmRecord :: [Doc] -> Doc
elmRecord = encloseSep (lbrace <> space) (line <> rbrace) (comma <> space)

elmList :: [Doc] -> Doc
elmList [] = lbracket <> rbracket
elmList ds = lbracket <+> hsep (punctuate (line <> comma) ds) <$> rbracket

elmListOfMaybes :: [Doc] -> Doc
elmListOfMaybes [] = lbracket <> rbracket
elmListOfMaybes ds = "List.filterMap identity" <$> indent 4 (elmList ds)
