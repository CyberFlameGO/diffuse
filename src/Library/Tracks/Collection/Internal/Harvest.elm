module Tracks.Collection.Internal.Harvest exposing (harvest)

import Dict
import List.Extra as List
import Maybe.Extra as Maybe
import Tracks exposing (..)



-- 🍯


harvest : Parcel -> Parcel
harvest ( deps, collection ) =
    let
        harvested =
            case deps.searchResults of
                Just [] ->
                    []

                Just trackIds ->
                    collection.arranged
                        |> List.foldl harvester ( [], trackIds )
                        |> Tuple.first

                Nothing ->
                    collection.arranged

        filters =
            [ -- Favourites / Missing
              -----------------------
              if deps.favouritesOnly then
                Tuple.first >> .isFavourite >> (==) True

              else
                Tuple.first >> .isMissing >> (==) False
            ]

        theFilter x =
            List.foldl
                (\filter bool ->
                    if bool == True then
                        filter x

                    else
                        bool
                )
                True
                filters
    in
    harvested
        |> List.foldl
            (\( i, t ) ( dict, ( idx, prevIdentifiers ), acc ) ->
                let
                    s =
                        String.toLower (t.tags.artist ++ t.tags.title)
                in
                if theFilter ( i, t ) == False then
                    ( dict, ( idx, prevIdentifiers ), acc )

                else if deps.hideDuplicates && Dict.member s dict then
                    ( dict, ( idx, prevIdentifiers ), acc )

                else
                    let
                        prevGroup =
                            Maybe.unwrap
                                ""
                                .name
                                prevIdentifiers.group

                        newIdentifiers =
                            { i
                                | group =
                                    Maybe.map
                                        (\g -> { g | firstInGroup = prevGroup /= g.name })
                                        i.group
                                , indexInList = idx
                            }
                    in
                    ( if deps.hideDuplicates then
                        Dict.insert s () dict

                      else
                        dict
                      --
                    , ( idx + 1, newIdentifiers )
                    , ( newIdentifiers, t ) :: acc
                    )
            )
            ( Dict.empty, ( 0, Tracks.emptyIdentifiers ), [] )
        |> (\( a, b, c ) -> c)
        |> (\h -> { collection | harvested = List.reverse h })
        |> (\c -> ( deps, c ))


harvester :
    IdentifiedTrack
    -> ( List IdentifiedTrack, List String )
    -> ( List IdentifiedTrack, List String )
harvester ( i, t ) ( acc, trackIds ) =
    case List.findIndex ((==) t.id) trackIds of
        Just idx ->
            ( acc ++ [ ( i, t ) ]
            , List.removeAt idx trackIds
            )

        Nothing ->
            ( acc
            , trackIds
            )
