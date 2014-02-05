% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.
%
-module(couch_httpd_bulk_get).

-include_lib("couch/include/couch_db.hrl").
-include("couch_httpd.hrl").

-export([handle_req/2]).

handle_req(#httpd{method='POST',path_parts=[_,<<"_bulk_get">>],
              mochi_req=MochiReq}=Req, Db) ->
    couch_httpd:validate_ctype(Req, "application/json"),
    couch_httpd:validate_ctype(Req, "application/json"),
    {JsonProps} = couch_httpd:json_body_obj(Req),
    case couch_util:get_value(<<"docs">>, JsonProps) of
       undefined ->
            couch_httpd:send_error(Req, 400,
                       <<"bad_request">>, <<"Missing JSON list of
                                          'docs'">>);
        DocsArray ->
            #doc_query_args{
                options = Options
            } = couch_httpd_db:parse_doc_query(Req),

            %% start the response
            {Resp, Boundary} = case MochiReq:accepts_content_type("multipart/mixed") of
                false ->
                    {ok, Resp1} = couch_httpd:start_json_response(Req, 200),
                    couch_httpd:send_chunk(Resp1, "["),
                    {Resp1, nil};
                true ->
                    Boundary1 = couch_uuids:random(),
                    CType = {"Content-Type", "multipart/mixed; boundary=\"" ++
                             ?b2l(Boundary1) ++  "\""},
                    {ok, Resp1} = couch_httpd:start_chunked_response(Req, 200,
                                                                     [CType]),
                    {Resp1, Boundary1}
            end,

            lists:foldr(fun({Props}, Acc) ->
                        DocId = couch_util:get_value(<<"id">>, Props),
                        Revs = [?b2l(couch_util:get_value(<<"rev">>,
                                                          Props, ""))],
                        Revs1 = couch_doc:parse_revs(Revs),
                        Options1 = case couch_util:get_value(<<"atts_since">>,
                                                             Props, []) of
                            [] ->
                                Options;
                            RevList when is_list(RevList) ->
                                RevList1 = couch_doc:parse_revs(RevList),
                                [{atts_since, RevList1}, attachments |Options]
                        end,
                        {ok, Results} = couch_db:open_doc_revs(Db, DocId,
                                                               Revs1, Options),
                        case Boundary of
                            nil ->
                                send_docs(Resp, DocId, Results,
                                          Options1, Acc);
                            _ ->
                                send_docs_multipart(Resp, DocId, Results,
                                                    Boundary, Options1)
                        end,
                        ","
                end, "", DocsArray),

            %% finish the response
            case Boundary of
                nil ->
                    couch_httpd:end_json_response(Resp);
                _ ->
                    couch_httpd:send_chunk(Resp, <<"--">>),
                    couch_httpd:last_chunk(Resp)
            end
    end;
handle_req(#httpd{path_parts=[_,<<"_bulk_get">>]}=Req, _Db) ->
    couch_httpd:send_method_not_allowed(Req, "POST").

send_docs(Resp, DocId, Results, Options, Sep) ->
    couch_httpd:send_chunk(Resp, [Sep, "{ \"id\": \"",
                                  ?JSON_ENCODE(DocId), "\", \"docs\": ["]),
    lists:foldl(
        fun(Result, AccSeparator) ->
                case Result of
                    {ok, Doc} ->
                        JsonDoc = couch_doc:to_json_obj(Doc, Options),
                        Json = ?JSON_ENCODE({[{ok, JsonDoc}]}),
                        couch_httpd:send_chunk(Resp, AccSeparator ++ Json);
                    {{not_found, missing}, RevId} ->
                        RevStr = couch_doc:rev_to_str(RevId),
                        Json = ?JSON_ENCODE({[{"missing", RevStr}]}),
                        couch_httpd:send_chunk(Resp, AccSeparator ++ Json)
                end,
                "," % AccSeparator now has a comma
        end, "", Results),
    couch_httpd:send_chunk(Resp, "]}").

send_docs_multipart(Resp, DocId, Results, OuterBoundary, Options0) ->
    Options = [attachments, follows, att_encoding_info | Options0],
    InnerBoundary = couch_uuids:random(),
    couch_httpd:send_chunk(Resp, <<"--", OuterBoundary/binary>>),
    lists:foreach(
        fun({ok, #doc{atts=Atts}=Doc}) ->
                JsonBytes = ?JSON_ENCODE(couch_doc:to_json_obj(Doc, Options)),
                {ContentType, _Len} = couch_doc:len_doc_to_multi_part_stream(
                        InnerBoundary, JsonBytes, Atts, true),
                Hdr = <<"\r\nContent-Type: ", ContentType/binary, "\r\n\r\n">>,
                couch_httpd:send_chunk(Resp, Hdr),
                couch_doc:doc_to_multi_part_stream(InnerBoundary, JsonBytes,
                                                   Atts, fun(Data) ->
                            couch_httpd:send_chunk(Resp, Data)
                    end, true),
                couch_httpd:send_chunk(Resp, <<"\r\n--", OuterBoundary/binary>>);
            ({{not_found, missing}, RevId}) ->
                RevStr = couch_doc:rev_to_str(RevId),
                Body = {[{<<"id">>, DocId},
                         {<<"error">>, <<"not_found">>},
                         {<<"reason">>, <<"missing">>},
                         {<<"status">>, 400}]},
                Json = ?JSON_ENCODE(Body),
                {ContentType, _Len} = couch_doc:len_doc_to_multi_part_stream(
                        InnerBoundary, Json, [], true),

                Hdr = <<"\r\nContent-Type: ", ContentType/binary, "\r\n\r\n">>,
                couch_httpd:send_chunk(Resp, Hdr),
                couch_doc:doc_to_multi_part_stream(InnerBoundary, Json,
                                                   [], fun(Data) ->
                            couch_httpd:send_chunk(Resp, Data)
                    end, true),
                couch_httpd:send_chunk(Resp, <<"\r\n--", OuterBoundary/binary>>)
        end, Results).
