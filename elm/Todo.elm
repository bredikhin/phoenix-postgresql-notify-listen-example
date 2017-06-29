module Todo exposing (..)

{-| TodoMVC implemented in Elm, using plain HTML and CSS for rendering.

This application is broken up into three key parts:

  1. Model  - a full definition of the application's state
  2. Update - a way to step the application state forward
  3. View   - a way to visualize our application state with HTML

This clean division of concerns is a core part of Elm. You can read more about
this in <http://guide.elm-lang.org/architecture/index.html>
-}

import Dom
import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (..)
import Html.Keyed as Keyed
import Html.Lazy exposing (lazy, lazy2)
import Json.Decode as Json
import String
import Task
import Phoenix.Socket
import Phoenix.Channel
import Phoenix.Push
import Json.Encode as Encode
import Debug exposing (log)

main : Program Never Model Msg
main =
    Html.program
        { init = init
        , view = view
        , update = update
        , subscriptions = subscriptions
        }


-- MODEL


-- The full application state of our todo app.
type alias Model =
    { entries : List Entry
    , field : String
    , uid : Int
    , visibility : String
    , socket : Phoenix.Socket.Socket Msg
    }


type alias Entry =
    { description : String
    , completed : Bool
    , editing : Bool
    , id : Int
    }


newEntry : String -> Int -> Entry
newEntry desc id =
    { description = desc
    , completed = False
    , editing = False
    , id = id
    }


init : ( Model, Cmd Msg )
init =
    let
        channelName = "todo:list"
        channel = Phoenix.Channel.init channelName
            |> Phoenix.Channel.onJoin (always RequestEntries)
        socketInit = Phoenix.Socket.init "ws://localhost:4000/socket/websocket"
            |> Phoenix.Socket.on "todos" channelName ReceiveEntries
        ( socket, cmd ) =
            Phoenix.Socket.join channel socketInit
    in
        { entries = []
        , visibility = "All"
        , field = ""
        , uid = 0
        , socket = socket
        } ! [ Cmd.map SocketMsg cmd ]



-- UPDATE


{-| Users of our app can trigger messages by clicking and typing. These
messages are fed into the `update` function as they occur, letting us react
to them.
-}
type Msg
    = NoOp
    | UpdateField String
    | EditingEntry Int Bool
    | UpdateEntry Int String
    | SyncEntry Int
    | Add
    | Delete Int
    | DeleteComplete
    | Check Int Bool
    | CheckAll Bool
    | ChangeVisibility String
    | SocketMsg (Phoenix.Socket.Msg Msg)
    | RequestEntries
    | ReceiveEntries Encode.Value



-- How we update our Model on a given Msg?
update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        NoOp ->
            model ! []

        Add ->
            let
                payload =
                    Encode.object
                        [ ( "todo", Encode.object
                            [ ("task", Encode.string model.field)
                            , ("id", Encode.int (model.uid + 1))
                            , ("completed", Encode.bool False)
                            ]
                          )
                        ]

                push =
                    Phoenix.Push.init "insert" "todo:list"
                        |> Phoenix.Push.withPayload payload

                ( socket, cmd ) =
                    Phoenix.Socket.push push model.socket
            in
                { model | socket = socket, field = "" }
                    ! [ Cmd.map SocketMsg cmd ]

        UpdateField str ->
            { model | field = str }
                ! []

        EditingEntry id isEditing ->
            let
                updateEntry t =
                    if t.id == id then
                        { t | editing = isEditing }
                    else
                        t

                focus =
                    Dom.focus ("todo-" ++ toString id)

                (updatedModel, cmd) =
                    if (not isEditing) then
                        update (SyncEntry id) model
                    else
                        (model, Cmd.none)
            in
                { updatedModel | entries = List.map updateEntry updatedModel.entries }
                    ! [ Task.attempt (\_ -> NoOp) focus, cmd ]

        SyncEntry id ->
            let
                edited = List.head (List.filter (\x -> x.id == id) model.entries)
                ( socket, cmd ) =
                    case edited of
                        Nothing -> (model.socket, Cmd.none)
                        Just entry ->
                            let
                                payload =
                                    Encode.object
                                        [ ( "todo", Encode.object
                                            [ ("task", Encode.string entry.description)
                                            , ("id", Encode.int entry.id)
                                            , ("completed", Encode.bool entry.completed)
                                            ]
                                          )
                                        ]

                                push =
                                    Phoenix.Push.init "update" "todo:list"
                                        |> Phoenix.Push.withPayload payload

                          in
                              Phoenix.Socket.push push model.socket
            in
                { model | socket = socket }
                    ! [ Cmd.map SocketMsg cmd ]

        UpdateEntry id task ->
            let
                updateEntry t =
                    if t.id == id then
                        { t | description = task }
                    else
                        t
            in
                { model | entries = List.map updateEntry model.entries }
                    ! []

        Delete id ->
            let
                deleted = List.head (List.filter (\x -> x.id == id) model.entries)
                ( socket, cmd ) =
                    case deleted of
                        Nothing -> (model.socket, Cmd.none)
                        Just entry ->
                            let
                                payload =
                                    Encode.object
                                        [ ( "todo", Encode.object
                                            [ ("id", Encode.int entry.id) ]
                                          )
                                        ]

                                push =
                                    Phoenix.Push.init "delete" "todo:list"
                                        |> Phoenix.Push.withPayload payload

                          in
                              Phoenix.Socket.push push model.socket
            in
                { model | socket = socket }
                    ! [ Cmd.map SocketMsg cmd ]

        DeleteComplete ->
            let
                deleteEntry t (model, cmdList) =
                    let
                        (updatedModel, newCmd) = update (Delete t.id) model
                    in
                        (updatedModel, List.append cmdList [ newCmd ])
                (updatedModel, cmdList) = List.foldr
                    deleteEntry (model, [])
                    (List.filter .completed model.entries)
            in
                updatedModel ! cmdList

        Check id isCompleted ->
            let
                updateEntry t =
                    if t.id == id then
                        { t | completed = isCompleted }
                    else
                        t
                updatedModel = { model | entries = List.map updateEntry model.entries }
            in
                update (SyncEntry id) updatedModel

        CheckAll isCompleted ->
            let
                updateEntry t =
                    { t | completed = isCompleted }
                allCheckedModel = { model | entries = List.map updateEntry model.entries }
                syncEntry t (model, cmdList) =
                    let
                        (updatedModel, newCmd) = update (SyncEntry t.id) model
                    in
                        (updatedModel, List.append cmdList [ newCmd ])
                (updatedModel, cmdList) = List.foldr
                    syncEntry (allCheckedModel, [])
                    allCheckedModel.entries
            in
                updatedModel ! cmdList

        ChangeVisibility visibility ->
            { model | visibility = visibility }
                ! []

        SocketMsg msg ->
            let
                ( socket, cmd ) =
                    Phoenix.Socket.update msg model.socket
            in
                { model | socket = socket } ! [ Cmd.map SocketMsg cmd ]

        RequestEntries ->
            let
                push =
                    Phoenix.Push.init "todos" "todo:list"
                        |> Phoenix.Push.onOk ReceiveEntries
                ( socket, cmd ) =
                    Phoenix.Socket.push push model.socket
            in
                { model | socket = socket } ! [ Cmd.map SocketMsg cmd ]

        ReceiveEntries raw ->
            let
                decoded =
                    Json.decodeValue
                        ( Json.field "todos"
                            ( Json.list
                                ( Json.map4
                                    Entry
                                    (Json.field "task" Json.string)
                                    (Json.field "completed" Json.bool)
                                    (Json.succeed False)
                                    (Json.field "id" Json.int)
                                )
                            )
                        )
                        raw
                nextId xs = List.foldl (\x y->if x.id > y then x.id else y) 0 xs
            in
                case decoded of
                    Ok entries ->
                        { model | entries = entries, uid = nextId entries } ! []
                    Err error ->
                        model ! []


-- VIEW


view : Model -> Html Msg
view model =
    div
        [ class "todomvc-wrapper"
        , style [ ( "visibility", "hidden" ) ]
        ]
        [ section
            [ class "todoapp" ]
            [ lazy viewInput model.field
            , lazy2 viewEntries model.visibility model.entries
            , lazy2 viewControls model.visibility model.entries
            ]
        , infoFooter
        ]


viewInput : String -> Html Msg
viewInput task =
    header
        [ class "header" ]
        [ h1 [] [ text "todos" ]
        , input
            [ class "new-todo"
            , placeholder "What needs to be done?"
            , autofocus True
            , value task
            , name "newTodo"
            , onInput UpdateField
            , onEnter Add
            ]
            []
        ]


onEnter : Msg -> Attribute Msg
onEnter msg =
    let
        isEnter code =
            if code == 13 then
                Json.succeed msg
            else
                Json.fail "not ENTER"
    in
        on "keydown" (Json.andThen isEnter keyCode)



-- VIEW ALL ENTRIES


viewEntries : String -> List Entry -> Html Msg
viewEntries visibility entries =
    let
        isVisible todo =
            case visibility of
                "Completed" ->
                    todo.completed

                "Active" ->
                    not todo.completed

                _ ->
                    True

        allCompleted =
            List.all .completed entries

        cssVisibility =
            if List.isEmpty entries then
                "hidden"
            else
                "visible"
    in
        section
            [ class "main"
            , style [ ( "visibility", cssVisibility ) ]
            ]
            [ input
                [ class "toggle-all"
                , type_ "checkbox"
                , name "toggle"
                , checked allCompleted
                , onClick (CheckAll (not allCompleted))
                ]
                []
            , label
                [ for "toggle-all" ]
                [ text "Mark all as complete" ]
            , Keyed.ul [ class "todo-list" ] <|
                List.map viewKeyedEntry (List.filter isVisible entries)
            ]



-- VIEW INDIVIDUAL ENTRIES


viewKeyedEntry : Entry -> ( String, Html Msg )
viewKeyedEntry todo =
    ( toString todo.id, lazy viewEntry todo )


viewEntry : Entry -> Html Msg
viewEntry todo =
    li
        [ classList [ ( "completed", todo.completed ), ( "editing", todo.editing ) ] ]
        [ div
            [ class "view" ]
            [ input
                [ class "toggle"
                , type_ "checkbox"
                , checked todo.completed
                , onClick (Check todo.id (not todo.completed))
                ]
                []
            , label
                [ onDoubleClick (EditingEntry todo.id True) ]
                [ text todo.description ]
            , button
                [ class "destroy"
                , onClick (Delete todo.id)
                ]
                []
            ]
        , input
            [ class "edit"
            , value todo.description
            , name "title"
            , id ("todo-" ++ toString todo.id)
            , onInput (UpdateEntry todo.id)
            , onBlur (EditingEntry todo.id False)
            , onEnter (EditingEntry todo.id False)
            ]
            []
        ]



-- VIEW CONTROLS AND FOOTER


viewControls : String -> List Entry -> Html Msg
viewControls visibility entries =
    let
        entriesCompleted =
            List.length (List.filter .completed entries)

        entriesLeft =
            List.length entries - entriesCompleted
    in
        footer
            [ class "footer"
            , hidden (List.isEmpty entries)
            ]
            [ lazy viewControlsCount entriesLeft
            , lazy viewControlsFilters visibility
            , lazy viewControlsClear entriesCompleted
            ]


viewControlsCount : Int -> Html Msg
viewControlsCount entriesLeft =
    let
        item_ =
            if entriesLeft == 1 then
                " item"
            else
                " items"
    in
        span
            [ class "todo-count" ]
            [ strong [] [ text (toString entriesLeft) ]
            , text (item_ ++ " left")
            ]


viewControlsFilters : String -> Html Msg
viewControlsFilters visibility =
    ul
        [ class "filters" ]
        [ visibilitySwap "#/" "All" visibility
        , text " "
        , visibilitySwap "#/active" "Active" visibility
        , text " "
        , visibilitySwap "#/completed" "Completed" visibility
        ]


visibilitySwap : String -> String -> String -> Html Msg
visibilitySwap uri visibility actualVisibility =
    li
        [ onClick (ChangeVisibility visibility) ]
        [ a [ href uri, classList [ ( "selected", visibility == actualVisibility ) ] ]
            [ text visibility ]
        ]


viewControlsClear : Int -> Html Msg
viewControlsClear entriesCompleted =
    button
        [ class "clear-completed"
        , hidden (entriesCompleted == 0)
        , onClick DeleteComplete
        ]
        [ text ("Clear completed (" ++ toString entriesCompleted ++ ")")
        ]


infoFooter : Html msg
infoFooter =
    footer [ class "info" ]
        [ p [] [ text "Double-click to edit a todo" ]
        , p []
            [ text "Written by "
            , a [ href "https://github.com/evancz" ] [ text "Evan Czaplicki" ]
            ]
        , p []
            [ text "Part of "
            , a [ href "http://todomvc.com" ] [ text "TodoMVC" ]
            ]
        ]


-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions model =
    Phoenix.Socket.listen model.socket SocketMsg
