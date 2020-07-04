module UI.Tracks.State exposing (..)

import Alien
import Base64
import Common exposing (..)
import Conditional exposing (ifThenElse)
import ContextMenu
import Coordinates exposing (Coordinates)
import Dict
import Dict.Extra as Dict
import Html.Events.Extra.Mouse as Mouse
import InfiniteList
import Json.Decode as Json
import Json.Encode
import List.Ext as List
import List.Extra as List
import Maybe.Extra as Maybe
import Notifications
import Playlists exposing (Playlist)
import Queue
import Return exposing (andThen, return)
import Return.Ext as Return
import Sources
import Sources.Processing exposing (HttpMethod(..))
import Task
import Task.Extra as Task
import Tracks exposing (..)
import Tracks.Collection as Collection
import Tracks.Encoding as Encoding
import Tracks.Favourites as Favourites
import UI.Common.State as Common exposing (showNotification)
import UI.DnD as DnD
import UI.Page
import UI.Ports as Ports
import UI.Queue.State as Queue
import UI.Tracks.ContextMenu as Tracks
import UI.Tracks.Scene.Covers
import UI.Tracks.Scene.List
import UI.Tracks.Types as Tracks exposing (..)
import UI.Types as UI exposing (Manager, Model, Msg(..))
import UI.User.State.Export as User
import User.Layer exposing (HypaethralData)



-- 📣


update : Tracks.Msg -> Manager
update msg =
    case msg of
        Download a b ->
            download a b

        DownloadFinished ->
            downloadFinished

        Harvest ->
            harvest

        MarkAsSelected a b ->
            markAsSelected a b

        ScrollToNowPlaying ->
            scrollToNowPlaying

        ToggleCachedOnly ->
            toggleCachedOnly

        ToggleFavouritesOnly ->
            toggleFavouritesOnly

        ToggleHideDuplicates ->
            toggleHideDuplicates

        -----------------------------------------
        -- Cache
        -----------------------------------------
        ClearCache ->
            clearCache

        RemoveFromCache a ->
            removeFromCache a

        StoreInCache a ->
            storeInCache a

        StoredInCache a b ->
            storedInCache a b

        ---------
        -- Covers
        ---------
        GotCachedCover a ->
            gotCachedCover a

        InsertCoverCache a ->
            insertCoverCache a

        -----------------------------------------
        -- Collection
        -----------------------------------------
        Add a ->
            add a

        RemoveByPaths a ->
            removeByPaths a

        RemoveBySourceId a ->
            removeBySourceId a

        SortBy a ->
            sortBy a

        ToggleFavourite a ->
            toggleFavourite a

        -----------------------------------------
        -- Groups
        -----------------------------------------
        DisableGrouping ->
            disableGrouping

        GroupBy a ->
            groupBy a

        -----------------------------------------
        -- Menus
        -----------------------------------------
        ShowCoverMenu a b ->
            showCoverMenu a b

        ShowCoverMenuWithSmallDelay a b ->
            showCoverMenuWithDelay a b

        ShowTracksMenu a b c ->
            showTracksMenu a b c

        ShowTracksMenuWithSmallDelay a b c ->
            showTracksMenuWithDelay a b c

        ShowViewMenu a b ->
            showViewMenu a b

        -----------------------------------------
        -- Scenes
        -----------------------------------------
        ChangeScene a ->
            changeScene a

        DeselectCover ->
            deselectCover

        InfiniteListMsg a ->
            infiniteListMsg a

        SelectCover a ->
            selectCover a

        -----------------------------------------
        -- Search
        -----------------------------------------
        ClearSearch ->
            clearSearch

        Search ->
            search

        SetSearchResults a ->
            setSearchResults a

        SetSearchTerm a ->
            setSearchTerm a



-- 🔱


add : Json.Value -> Manager
add encodedTracks model =
    model
        |> reviseCollection
            (encodedTracks
                |> Json.decodeValue (Json.list Encoding.trackDecoder)
                |> Result.withDefault []
                |> Collection.add
            )
        |> andThen search


changeScene : Scene -> Manager
changeScene scene model =
    (case scene of
        Covers ->
            Ports.loadAlbumCovers ()

        List ->
            Cmd.none
    )
        |> return { model | scene = scene, selectedCover = Nothing }
        |> andThen Common.forceTracksRerender
        |> andThen User.saveEnclosedUserData


clearCache : Manager
clearCache model =
    model.cachedTracks
        |> Json.Encode.list Json.Encode.string
        |> Alien.broadcast Alien.RemoveTracksFromCache
        |> Ports.toBrain
        |> return { model | cachedTracks = [] }
        |> andThen harvest
        |> andThen User.saveEnclosedUserData
        |> andThen
            ("Tracks cache was cleared"
                |> Notifications.warning
                |> Common.showNotification
            )


clearSearch : Manager
clearSearch model =
    { model | searchResults = Nothing, searchTerm = Nothing }
        |> reviseCollection Collection.harvest
        |> andThen User.saveEnclosedUserData


deselectCover : Manager
deselectCover model =
    Return.singleton { model | selectedCover = Nothing }


download : String -> List Track -> Manager
download zipName tracks model =
    let
        notification =
            Notifications.stickyWarning "Downloading tracks ..."

        downloading =
            Just { notificationId = Notifications.id notification }
    in
    [ ( "zipName", Json.Encode.string zipName )
    , ( "trackIds"
      , tracks
            |> List.map .id
            |> Json.Encode.list Json.Encode.string
      )
    ]
        |> Json.Encode.object
        |> Alien.broadcast Alien.DownloadTracks
        |> Ports.toBrain
        |> return { model | downloading = downloading }
        |> andThen (Common.showNotification notification)


downloadFinished : Manager
downloadFinished model =
    case model.downloading of
        Just { notificationId } ->
            Common.dismissNotification
                { id = notificationId }
                { model | downloading = Nothing }

        Nothing ->
            Return.singleton model


disableGrouping : Manager
disableGrouping model =
    { model | grouping = Nothing }
        |> reviseCollection Collection.arrange
        |> andThen User.saveEnclosedUserData


failedToStoreInCache : List String -> Manager
failedToStoreInCache trackIds m =
    showNotification
        (Notifications.error "Failed to store track in cache")
        { m | cachingTracksInProgress = List.without trackIds m.cachingTracksInProgress }


finishedStoringInCache : List String -> Manager
finishedStoringInCache trackIds model =
    { model
        | cachedTracks = model.cachedTracks ++ trackIds
        , cachingTracksInProgress = List.without trackIds model.cachingTracksInProgress
    }
        |> (\m ->
                -- When a context menu of a track is open,
                -- it should be "rerendered" in case
                -- the track is no longer being downloaded.
                case m.contextMenu of
                    Just contextMenu ->
                        let
                            isTrackContextMenu =
                                ContextMenu.anyItem
                                    (.label >> (==) "Downloading ...")
                                    contextMenu

                            coordinates =
                                ContextMenu.coordinates contextMenu
                        in
                        if isTrackContextMenu then
                            showTracksMenu Nothing { alt = False } coordinates m

                        else
                            Return.singleton m

                    Nothing ->
                        Return.singleton m
           )
        |> andThen harvest
        |> andThen User.saveEnclosedUserData


generateCovers : Manager
generateCovers model =
    let
        groupFn =
            coverGroup model.sortBy

        makeCoverFn =
            makeCover model.sortBy
    in
    model.tracks.harvested
        |> List.indexedFoldr
            (\idx identifiedTrack { covers, gathering } ->
                let
                    group =
                        groupFn identifiedTrack

                    ( identifiers, track ) =
                        identifiedTrack

                    { artist, album } =
                        track.tags
                in
                if group /= gathering.previousGroup then
                    -- New group, make cover for previous group
                    let
                        { collection, selectedCover } =
                            makeCoverFn gathering covers model.selectedCover
                    in
                    { gathering =
                        { acc = [ identifiedTrack ]
                        , accIds = [ track.id ]
                        , previousGroup = group
                        , previousTrack = track
                        , selectedCover = selectedCover

                        --
                        , currentAlbumSequence = Just ( identifiedTrack, 1 )
                        , largestAlbumSequence = Nothing

                        --
                        , currentAlbumFavsSequence = Just ( identifiedTrack, ifThenElse identifiers.isFavourite 1 0 )
                        , largestAlbumFavsSequence = Nothing

                        --
                        , currentArtistSequence = Just ( identifiedTrack, 1 )
                        , largestArtistSequence = Nothing
                        }
                    , covers =
                        case group of
                            "<missing>" ->
                                covers

                            _ ->
                                collection
                    }

                else
                    -- Same group
                    { gathering =
                        { acc = identifiedTrack :: gathering.acc
                        , accIds = track.id :: gathering.accIds
                        , previousGroup = group
                        , previousTrack = track
                        , selectedCover = gathering.selectedCover

                        -- Album sequence
                        -----------------
                        , currentAlbumSequence =
                            if album /= gathering.previousTrack.tags.album then
                                Just ( identifiedTrack, 1 )

                            else
                                increaseSequence gathering.currentAlbumSequence

                        --
                        , largestAlbumSequence =
                            if album /= gathering.previousTrack.tags.album then
                                resolveLargestSequence
                                    gathering.currentAlbumSequence
                                    gathering.largestAlbumSequence

                            else
                                gathering.largestAlbumSequence

                        -- Album favourites sequence
                        ----------------------------
                        , currentAlbumFavsSequence =
                            if album /= gathering.previousTrack.tags.album then
                                Just ( identifiedTrack, ifThenElse identifiers.isFavourite 1 0 )

                            else if identifiers.isFavourite then
                                increaseSequence gathering.currentAlbumFavsSequence

                            else
                                gathering.currentAlbumFavsSequence

                        --
                        , largestAlbumFavsSequence =
                            if album /= gathering.previousTrack.tags.album then
                                resolveLargestSequence
                                    gathering.currentAlbumFavsSequence
                                    gathering.largestAlbumFavsSequence

                            else
                                gathering.largestAlbumFavsSequence

                        -- Artist sequence
                        ------------------
                        , currentArtistSequence =
                            if artist /= gathering.previousTrack.tags.artist then
                                Just ( identifiedTrack, 1 )

                            else
                                increaseSequence gathering.currentArtistSequence

                        --
                        , largestArtistSequence =
                            if artist /= gathering.previousTrack.tags.artist then
                                resolveLargestSequence
                                    gathering.currentArtistSequence
                                    gathering.largestArtistSequence

                            else
                                gathering.largestArtistSequence
                        }
                    , covers =
                        covers
                    }
            )
            { covers =
                []
            , gathering =
                { acc = []
                , accIds = []
                , previousGroup = ""
                , previousTrack = emptyTrack
                , selectedCover = Nothing

                --
                , currentAlbumSequence = Nothing
                , largestAlbumSequence = Nothing
                , currentAlbumFavsSequence = Nothing
                , largestAlbumFavsSequence = Nothing
                , currentArtistSequence = Nothing
                , largestArtistSequence = Nothing
                }
            }
        |> (\{ covers, gathering } ->
                let
                    { collection, selectedCover } =
                        makeCoverFn gathering covers model.selectedCover
                in
                { model
                    | covers = collection
                    , selectedCover = selectedCover
                }
           )
        |> Return.communicate
            (Ports.loadAlbumCovers ())
        |> andThen
            (case model.scene of
                Covers ->
                    Common.forceTracksRerender

                List ->
                    Return.singleton
            )


gotCachedCover : Json.Value -> Manager
gotCachedCover json model =
    let
        cachedCovers =
            Maybe.withDefault Dict.empty model.cachedCovers
    in
    json
        |> Json.decodeValue
            (Json.map2
                Tuple.pair
                (Json.field "key" Json.string)
                (Json.field "url" Json.string)
            )
        |> Result.map (\( key, url ) -> Dict.insert key url cachedCovers)
        |> Result.map (\dict -> { model | cachedCovers = Just dict })
        |> Result.withDefault model
        |> Return.singleton


groupBy : Tracks.Grouping -> Manager
groupBy grouping model =
    { model | grouping = Just grouping }
        |> reviseCollection Collection.arrange
        |> andThen User.saveEnclosedUserData


harvest : Manager
harvest =
    reviseCollection Collection.harvest


infiniteListMsg : InfiniteList.Model -> Manager
infiniteListMsg infiniteList model =
    return
        { model | infiniteList = infiniteList }
        (Ports.loadAlbumCovers ())


insertCoverCache : Json.Value -> Manager
insertCoverCache json model =
    json
        |> Json.decodeValue (Json.dict Json.string)
        |> Result.map (\dict -> { model | cachedCovers = Just dict })
        |> Result.withDefault model
        |> Return.singleton


markAsSelected : Int -> { shiftKey : Bool } -> Manager
markAsSelected indexInList { shiftKey } model =
    let
        selection =
            if shiftKey then
                model.selectedTrackIndexes
                    |> List.head
                    |> Maybe.map
                        (\n ->
                            if n > indexInList then
                                List.range indexInList n

                            else
                                List.range n indexInList
                        )
                    |> Maybe.withDefault [ indexInList ]

            else
                [ indexInList ]
    in
    Return.singleton { model | selectedTrackIndexes = selection }


removeByPaths : Json.Value -> Manager
removeByPaths encodedParams model =
    let
        decoder =
            Json.map2
                Tuple.pair
                (Json.field "filePaths" <| Json.list Json.string)
                (Json.field "sourceId" Json.string)

        ( paths, sourceId ) =
            encodedParams
                |> Json.decodeValue decoder
                |> Result.withDefault ( [], missingId )

        { kept, removed } =
            Tracks.removeByPaths
                { sourceId = sourceId, paths = paths }
                model.tracks.untouched

        newCollection =
            { emptyCollection | untouched = kept }
    in
    { model | tracks = newCollection }
        |> reviseCollection Collection.identify
        |> andThen (removeFromCache removed)


removeBySourceId : String -> Manager
removeBySourceId sourceId model =
    let
        { kept, removed } =
            Tracks.removeBySourceId sourceId model.tracks.untouched

        newCollection =
            { emptyCollection | untouched = kept }
    in
    sourceId
        |> Json.Encode.string
        |> Alien.broadcast Alien.RemoveTracksBySourceId
        |> Ports.toBrain
        |> return { model | tracks = newCollection }
        |> andThen (reviseCollection Collection.identify)
        |> andThen (removeFromCache removed)


removeFromCache : List Track -> Manager
removeFromCache tracks model =
    let
        trackIds =
            List.map .id tracks
    in
    trackIds
        |> Json.Encode.list Json.Encode.string
        |> Alien.broadcast Alien.RemoveTracksFromCache
        |> Ports.toBrain
        |> return { model | cachedTracks = List.without trackIds model.cachedTracks }
        |> andThen harvest
        |> andThen User.saveEnclosedUserData


reviseCollection : (Parcel -> Parcel) -> Manager
reviseCollection collector model =
    resolveParcel
        (model
            |> makeParcel
            |> collector
        )
        model


search : Manager
search model =
    case ( model.searchTerm, model.searchResults ) of
        ( Just term, _ ) ->
            term
                |> String.trim
                |> Json.Encode.string
                |> Ports.giveBrain Alien.SearchTracks
                |> return model

        ( Nothing, Just _ ) ->
            reviseCollection Collection.harvest { model | searchResults = Nothing }

        ( Nothing, Nothing ) ->
            Return.singleton model


selectCover : Cover -> Manager
selectCover cover model =
    Return.singleton { model | selectedCover = Just cover }


setSearchResults : Json.Value -> Manager
setSearchResults json model =
    case model.searchTerm of
        Just _ ->
            json
                |> Json.decodeValue (Json.list Json.string)
                |> Result.withDefault []
                |> (\results -> { model | searchResults = Just results })
                |> reviseCollection Collection.harvest
                |> andThen (Common.toggleLoadingScreen Off)

        Nothing ->
            Return.singleton model


setSearchTerm : String -> Manager
setSearchTerm term model =
    User.saveEnclosedUserData
        (case String.trim term of
            "" ->
                { model | searchTerm = Nothing }

            _ ->
                { model | searchTerm = Just term }
        )


showCoverMenu : Cover -> Coordinates -> Manager
showCoverMenu cover coordinates model =
    let
        menuDependencies =
            { cached = model.cachedTracks
            , cachingInProgress = model.cachingTracksInProgress
            , currentTime = model.currentTime
            , selectedPlaylist = model.selectedPlaylist
            , lastModifiedPlaylistName = model.lastModifiedPlaylist
            , showAlternativeMenu = False
            , sources = model.sources
            }
    in
    coordinates
        |> Tracks.trackMenu menuDependencies cover.tracks
        |> Common.showContextMenuWithModel model


showCoverMenuWithDelay : Cover -> Coordinates -> Manager
showCoverMenuWithDelay a b model =
    Tracks.ShowCoverMenu a b
        |> TracksMsg
        |> Task.doDelayed 250
        |> return model


showTracksMenu : Maybe Int -> { alt : Bool } -> Coordinates -> Manager
showTracksMenu maybeTrackIndex { alt } coordinates model =
    let
        selection =
            case maybeTrackIndex of
                Just trackIndex ->
                    if List.isEmpty model.selectedTrackIndexes then
                        [ trackIndex ]

                    else if List.member trackIndex model.selectedTrackIndexes == False then
                        [ trackIndex ]

                    else
                        model.selectedTrackIndexes

                Nothing ->
                    model.selectedTrackIndexes

        menuDependencies =
            { cached = model.cachedTracks
            , cachingInProgress = model.cachingTracksInProgress
            , currentTime = model.currentTime
            , selectedPlaylist = model.selectedPlaylist
            , lastModifiedPlaylistName = model.lastModifiedPlaylist
            , showAlternativeMenu = alt
            , sources = model.sources
            }

        tracks =
            List.pickIndexes selection model.tracks.harvested
    in
    coordinates
        |> Tracks.trackMenu menuDependencies tracks
        |> Common.showContextMenuWithModel
            { model
                | dnd = DnD.initialModel
                , selectedTrackIndexes = selection
            }


showTracksMenuWithDelay : Maybe Int -> { alt : Bool } -> Coordinates -> Manager
showTracksMenuWithDelay a b c model =
    Tracks.ShowTracksMenu a b c
        |> TracksMsg
        |> Task.doDelayed 250
        |> return model


showViewMenu : Maybe Grouping -> Mouse.Event -> Manager
showViewMenu maybeGrouping mouseEvent model =
    mouseEvent.clientPos
        |> Coordinates.fromTuple
        |> Tracks.viewMenu model.cachedTracksOnly maybeGrouping
        |> Common.showContextMenuWithModel model


scrollToNowPlaying : Manager
scrollToNowPlaying model =
    model.nowPlaying
        |> Maybe.map
            (.identifiedTrack >> Tuple.second >> .id)
        |> Maybe.andThen
            (\id ->
                List.find
                    (Tuple.second >> .id >> (==) id)
                    model.tracks.harvested
            )
        |> Maybe.map
            (case model.scene of
                Covers ->
                    UI.Tracks.Scene.Covers.scrollToNowPlaying
                        model.viewport.width
                        model.covers

                List ->
                    UI.Tracks.Scene.List.scrollToNowPlaying model.tracks.harvested
            )
        |> Maybe.map
            (\cmd ->
                cmd
                    |> return { model | selectedCover = Nothing }
                    |> andThen (Common.changeUrlUsingPage UI.Page.Index)
            )
        |> Maybe.withDefault
            (Return.singleton model)


sortBy : SortBy -> Manager
sortBy property model =
    let
        sortDir =
            if model.sortBy /= property then
                Asc

            else if model.sortDirection == Asc then
                Desc

            else
                Asc
    in
    { model | sortBy = property, sortDirection = sortDir }
        |> reviseCollection Collection.arrange
        |> andThen User.saveEnclosedUserData


storeInCache : List Track -> Manager
storeInCache tracks model =
    let
        trackIds =
            List.map .id tracks

        notification =
            case tracks of
                [ t ] ->
                    ("__" ++ t.tags.title ++ "__ will be stored in the cache")
                        |> Notifications.success

                list ->
                    list
                        |> List.length
                        |> String.fromInt
                        |> (\s -> "__" ++ s ++ " tracks__ will be stored in the cache")
                        |> Notifications.success
    in
    tracks
        |> Json.Encode.list
            (\track ->
                Json.Encode.object
                    [ ( "trackId"
                      , Json.Encode.string track.id
                      )
                    , ( "url"
                      , track
                            |> Queue.makeTrackUrl
                                model.currentTime
                                model.sources
                            |> Json.Encode.string
                      )
                    ]
            )
        |> Alien.broadcast Alien.StoreTracksInCache
        |> Ports.toBrain
        |> return { model | cachingTracksInProgress = model.cachingTracksInProgress ++ trackIds }
        |> andThen (Common.showNotification notification)


storedInCache : Json.Value -> Maybe String -> Manager
storedInCache json maybeError =
    case
        ( maybeError
        , Json.decodeValue (Json.list Json.string) json
        )
    of
        ( Nothing, Ok list ) ->
            finishedStoringInCache list

        ( Nothing, Err err ) ->
            err
                |> Json.errorToString
                |> Notifications.error
                |> Common.showNotification

        ( Just _, Ok trackIds ) ->
            failedToStoreInCache trackIds

        ( Just err, Err _ ) ->
            err
                |> Notifications.error
                |> Common.showNotification


toggleCachedOnly : Manager
toggleCachedOnly model =
    { model | cachedTracksOnly = not model.cachedTracksOnly }
        |> reviseCollection Collection.harvest
        |> andThen User.saveEnclosedUserData
        |> andThen Common.forceTracksRerender


toggleFavourite : Int -> Manager
toggleFavourite index model =
    case List.getAt index model.tracks.harvested of
        Just ( i, t ) ->
            let
                newFavourites =
                    Favourites.toggleInFavouritesList ( i, t ) model.favourites

                effect collection =
                    collection
                        |> Collection.map (Favourites.toggleInTracksList t)
                        |> (if model.favouritesOnly then
                                Collection.harvest

                            else
                                identity
                           )

                selectedCover =
                    Maybe.map
                        (\cover ->
                            cover.tracks
                                |> Favourites.toggleInTracksList t
                                |> (\a -> { cover | tracks = a })
                        )
                        model.selectedCover
            in
            { model | favourites = newFavourites, selectedCover = selectedCover }
                |> reviseCollection effect
                |> andThen User.saveFavourites
                |> (if model.scene == Covers then
                        andThen generateCovers

                    else
                        identity
                   )

        Nothing ->
            Return.singleton model


toggleFavouritesOnly : Manager
toggleFavouritesOnly model =
    { model | favouritesOnly = not model.favouritesOnly }
        |> reviseCollection Collection.harvest
        |> andThen User.saveEnclosedUserData


toggleHideDuplicates : Manager
toggleHideDuplicates model =
    { model | hideDuplicates = not model.hideDuplicates }
        |> reviseCollection Collection.arrange
        |> andThen User.saveSettings



-- 📣  ░░  PARCEL


makeParcel : Model -> Parcel
makeParcel model =
    ( { cached = model.cachedTracks
      , cachedOnly = model.cachedTracksOnly
      , enabledSourceIds = Sources.enabledSourceIds model.sources
      , favourites = model.favourites
      , favouritesOnly = model.favouritesOnly
      , grouping = model.grouping
      , hideDuplicates = model.hideDuplicates
      , searchResults = model.searchResults
      , selectedPlaylist = model.selectedPlaylist
      , sortBy = model.sortBy
      , sortDirection = model.sortDirection
      }
    , model.tracks
    )


resolveParcel : Parcel -> Manager
resolveParcel ( deps, newCollection ) model =
    let
        scrollObj =
            Json.Encode.object
                [ ( "scrollTop", Json.Encode.int 0 ) ]

        scrollEvent =
            Json.Encode.object
                [ ( "target", scrollObj ) ]

        newScrollContext =
            scrollContext model

        collectionChanged =
            Collection.tracksChanged
                model.tracks.untouched
                newCollection.untouched

        harvestChanged =
            if collectionChanged then
                True

            else
                Collection.identifiedTracksChanged
                    model.tracks.harvested
                    newCollection.harvested

        arrangementChanged =
            if collectionChanged || harvestChanged then
                True

            else
                Collection.identifiedTracksChanged
                    model.tracks.arranged
                    newCollection.arranged

        searchChanged =
            newScrollContext /= model.tracks.scrollContext

        modelWithNewCollection =
            (if model.scene == List && searchChanged then
                \m -> { m | infiniteList = InfiniteList.updateScroll scrollEvent m.infiniteList }

             else
                identity
            )
                { model
                    | tracks =
                        { newCollection | scrollContext = newScrollContext }
                    , selectedTrackIndexes =
                        if collectionChanged || harvestChanged then
                            []

                        else
                            model.selectedTrackIndexes
                }
    in
    (if collectionChanged then
        andThen Common.generateDirectoryPlaylists
            >> andThen Queue.reset
            >> andThen generateCovers

     else if harvestChanged then
        andThen Queue.reset >> andThen generateCovers

     else if arrangementChanged then
        andThen generateCovers

     else
        identity
    )
        ( modelWithNewCollection
          -----------------------------------------
          -- Command
          -----------------------------------------
        , if searchChanged then
            case model.scene of
                Covers ->
                    UI.Tracks.Scene.Covers.scrollToTop

                List ->
                    UI.Tracks.Scene.List.scrollToTop

          else
            Cmd.none
        )


scrollContext : Model -> String
scrollContext model =
    String.concat
        [ Maybe.withDefault "" <| model.searchTerm
        , Maybe.withDefault "" <| Maybe.map .name model.selectedPlaylist
        ]



-- 📣  ░░  USER DATA


importHypaethral : HypaethralData -> Maybe Playlist -> Manager
importHypaethral data selectedPlaylist model =
    let
        adjustedModel =
            { model
                | favourites = data.favourites
                , hideDuplicates = Maybe.unwrap False .hideDuplicates data.settings
                , selectedPlaylist = selectedPlaylist
                , tracks = { emptyCollection | untouched = data.tracks }
            }
    in
    adjustedModel
        |> resolveParcel
            (adjustedModel
                |> makeParcel
                |> Collection.identify
            )
        |> andThen search
        |> (case model.searchTerm of
                Just _ ->
                    identity

                Nothing ->
                    andThen (Common.toggleLoadingScreen Off)
           )



-- ⚗️  ░░  COVERS


coverGroup : SortBy -> IdentifiedTrack -> String
coverGroup sort ( identifiers, { tags } as track ) =
    (case sort of
        Artist ->
            tags.artist

        Album ->
            -- There is the possibility of albums with the same name,
            -- such as "Greatests Hits".
            -- To make sure we treat those as different albums,
            -- we prefix the album by its parent directory.
            identifiers.parentDirectory ++ tags.album

        PlaylistIndex ->
            ""

        Title ->
            tags.title
    )
        |> String.trim
        |> String.toLower


coverKey : Bool -> Track -> String
coverKey isVariousArtists { tags } =
    if isVariousArtists then
        tags.album

    else
        tags.artist ++ " --- " ++ tags.album


makeCover sortBy_ gathering collection previouslySelectedCover =
    let
        closedGathering =
            { gathering
                | largestAlbumSequence =
                    resolveLargestSequence
                        gathering.currentAlbumSequence
                        gathering.largestAlbumSequence

                --
                , largestAlbumFavsSequence =
                    resolveLargestSequence
                        gathering.currentAlbumFavsSequence
                        gathering.largestAlbumFavsSequence

                --
                , largestArtistSequence =
                    resolveLargestSequence
                        gathering.currentArtistSequence
                        gathering.largestArtistSequence
            }
    in
    case closedGathering.acc of
        [] ->
            { collection = collection
            , selectedCover = closedGathering.selectedCover
            }

        fallback :: _ ->
            let
                cover =
                    makeCoverWithFallback sortBy_ closedGathering fallback
            in
            { collection = cover :: collection
            , selectedCover =
                case ( previouslySelectedCover, closedGathering.selectedCover ) of
                    ( Nothing, _ ) ->
                        Nothing

                    ( Just _, Just _ ) ->
                        closedGathering.selectedCover

                    ( Just sc, Nothing ) ->
                        case sortBy_ of
                            Artist ->
                                if cover.group == sc.group then
                                    Just cover

                                else
                                    Nothing

                            _ ->
                                if cover.key == sc.key then
                                    Just cover

                                else
                                    Nothing
            }


makeCoverWithFallback sortBy_ gathering fallback =
    let
        amountOfTracks =
            List.length gathering.accIds

        group =
            gathering.previousGroup

        identifiedTrack =
            gathering.largestAlbumFavsSequence
                |> Maybe.orElse gathering.largestAlbumSequence
                |> Maybe.map Tuple.first
                |> Maybe.withDefault fallback

        ( identifiers, track ) =
            identifiedTrack

        ( largestAlbumSequence, largestArtistSequence ) =
            ( Maybe.unwrap 0 Tuple.second gathering.largestAlbumSequence
            , Maybe.unwrap 0 Tuple.second gathering.largestArtistSequence
            )

        ( sameAlbum, sameArtist ) =
            ( largestAlbumSequence == amountOfTracks
            , largestArtistSequence == amountOfTracks
            )

        isVariousArtists =
            False
                || (amountOfTracks > 4 && largestArtistSequence < 3)
                || (String.toLower track.tags.artist == "va")
    in
    { key = Base64.encode (coverKey isVariousArtists track)
    , identifiedTrackCover = identifiedTrack

    --
    , focus =
        case sortBy_ of
            Artist ->
                "artist"

            _ ->
                "album"

    --
    , group = group
    , sameAlbum = sameAlbum
    , sameArtist = sameArtist

    --
    , trackIds = gathering.accIds
    , tracks = gathering.acc
    , variousArtists = isVariousArtists
    }



-- ⚗️  ░░  COVERS → SEQUENCES


increaseSequence =
    Maybe.map (Tuple.mapSecond ((+) 1))


resolveLargestSequence curr state =
    case ( curr, state ) of
        ( Just ( _, c ), Just ( _, s ) ) ->
            ifThenElse (c > s) curr state

        ( Just _, Nothing ) ->
            curr

        ( Nothing, Just _ ) ->
            state

        ( Nothing, Nothing ) ->
            Nothing