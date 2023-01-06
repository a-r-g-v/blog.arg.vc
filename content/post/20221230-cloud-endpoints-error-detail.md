---
title: "Cloud EndpointsでgRPCのエラー詳細をレスポンスに含める"
date: 2022-12-30T00:00:00+09:00
draft: false
---

# TL;DR
Google Cloud Endpointsを利用してgRPCサーバーをHTTP JSON APIサーバーに変換する場合で、エラー表現にRicher error modelを利用するケースにおいては
`google/rpc/error_details.proto` を proto descriptor setに含める（Protocol Buffer ファイルから import する）ことで、エラー詳細がレスポンスペイロードにJSONオブジェクトとして返却されるようになります。

# 背景

Google Cloud Endpointsを利用すると、gRPCで実装されたサーバーを一般的なHTTP JSON APIサーバーに変換することができます。
この変換は、[Extensible Service Proxy V2（ESPv2）](https://github.com/GoogleCloudPlatform/esp-v2) と呼ばれる Envoy ベースのゲートウェイサーバーを利用して行います。
ESPv2では、Envoy の [gRPC-JSON transcoder](https://www.envoyproxy.io/docs/envoy/latest/api-v3/extensions/filters/http/grpc_json_transcoder/v3/transcoder.proto) 機能を用いて変換処理を行っています。

また、一般にgRPCを利用されたサーバーでエラーを表現する場合、[「Standard error model」と「Richer error model」という2つの方法が知られています。](https://grpc.io/docs/guides/error/)
Standard error modelは単純な[gRPC ステータスコード](https://grpc.github.io/grpc/core/md_doc_statuscodes.html)を利用してエラーを表現する方法です。
Richer error modelは、事前にエラー詳細のフォーマットを規定しておき、メタデータにその情報を詰めてレスポンスすることで、ステータスコードよりも多くのエラー情報を表現することができる方法です。
例えば、[GoogleのAPI設計ガイドのエラー](https://cloud.google.com/apis/design/errors#error_model)では、Google APIs でのRicher error modelの適用例を知ることができます。

# 問題

前述の通り、Richer error modelではエラー詳細をメタデータに詰めてレスポンスします。
一方で、一般的なHTTP JSON APIサーバーでのエラーの表現方法は、レスポンスペイロードにエラーを表現するJSONオブジェクトを詰めて返却することです。
よって、何も工夫せずにGoogle Cloud Endpointsを利用すると、エラー詳細はレスポンスのHTTPヘッダー `grpc-status-details-bin` に詰められて返却されていまいます。
そのため、APIクライアントはHTTPヘッダーのエラー詳細をパーズして、エラーハンドリングを行う必要が発生してしまいます。
[これを行うライブラリ](https://github.com/shumbo/grpc-web-error-details)はありますが、余計な手間をAPIクライアントに押し付けることは問題です。

あるべき姿は、通常のHTTP JSON APIサーバーと同様に、エラー詳細をレスポンスペイロードにJSONオブジェクトとして返却することです。

# 対処方法

EnvoyのgRPC-JSON transcoderには[機能フラグ`convert_grpc_status`](https://www.envoyproxy.io/docs/envoy/latest/api-v3/extensions/filters/http/grpc_json_transcoder/v3/transcoder.proto)が存在しており、これを有効にするとHTTPヘッダー`grpc-status-details-bin`に含まれる
エラー詳細をデコードし、レスポンスペイロードにJSONオブジェクトを詰めて返却してくれます。この機能を利用することで、問題を解消することができます。[また、ESPv2ではこの機能フラグは有効になっています。](https://github.com/GoogleCloudPlatform/esp-v2/blob/6f914c6798b3239645935cfca64b61f33b6a9dab/src/go/configgenerator/filterconfig/filter_generator.go#L324)
しかし、私の環境では何故かこの機能が動作していませんでした。

原因は、`proto descriptor set`に [`google/rpc/error_details.proto`](https://github.com/googleapis/googleapis/blob/master/google/rpc/error_details.proto) を含めていないことでした。
Envoyの公式ドキュメントには以下の記述があります。

> In order to transcode the message, the google.rpc.RequestInfo type from the google/rpc/error_details.proto should be included in the configured proto descriptor set.

よって、このファイルを protoc を実行するプロジェクトに配置した上で、Protocol Buffer ファイルから `google/rpc/error_details.proto` を import する必要がありました。
上記を実施することで、エラー詳細がレスポンスペイロードにJSONオブジェクトとして返却されるようになりました。
