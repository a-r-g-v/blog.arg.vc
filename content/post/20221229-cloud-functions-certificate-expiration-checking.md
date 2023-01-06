---
title: "Cloud FunctionsでSSL/TLS証明書の有効期限チェッカーを実装する"
date: 2022-12-29T00:00:00+09:00
draft: false
---

# 背景
現代でもLet's encryptが利用できないような環境においては、SSL/TLS証明書の手動更新を実施する必要があります。
このようなSSL/TLS証明書の有効期限の管理は煩雑で忘れがちです。そのため、有効期限が近くなった場合にSlackなどに通知するシステムを利用することはよくあると思います。
著名なところでは、[Mackerel](https://ja.mackerel.io/)や[Google Cloud Monitoring](https://cloud.google.com/monitoring/uptime-checks)のUptime Checksを利用することで有効期限の監視とSlack通知を実装できます。

しかし、2022年10月から[Google Cloud MonitoringのUptime Checksは有料化](https://cloud.google.com/blog/products/infrastructure/updates-to-google-clouds-infrastructure-pricing?hl=en)され、[5エンドポイント以降では、1エンドポイントあたり約80USD/月](https://qiita.com/Saino/items/a51c2f6e1cebf3179a1a)課金されるようになりました。
そのため、複数のエンドポイントに対して有効期限を監視する場合は高額な料金がかかるようになりました。私は数十のエンドポイントを監視する必要があったため、代替ソリューションを検討する必要がありました。

# 要件
まず、新規に利用する監視ツールを増やしたくありませんでした。既にCloud Monitoringを利用して監視を行っているためです。闇雲にツールを増やすと、それを維持するコストがかかってしまいます。小規模な開発組織かつインフラを専属に見ているようなエンジニアが存在しないケースにおいて、なるべく利用するツールを絞ることは、オンボーディングやコミュニケーションコストを低く保つために重要です。

また、チェッカー自体がメンテンスレスで動作し続けてほしいという要求もありました。チェッカーが動作しなかったことにより、SSL/TLS証明書の有効期限切れに気づけないという問題を避けたかったためです。

さらに、なるべくイニシャルコスト・ランニングコストどちらも小さくしたいという要求もありました。

# 実装
上記の要件を満たすために、ここではCloud Functionsを用いてSSL/TLS証明書の有効期限の検出ロジックを実装しました。検出ロジックでは、SSL/TLS証明書をフェッチし、残り期限が7日以下であればSlack通知をするようにします。

また、Cloud Schedulerを利用して、毎日当該のFunctionsを起動するように構成しました。また、Cloud Schedulerでは再試行の構成を行うことができます。Functionsが失敗した場合に備えて再試行の構成を行うことでチェッカーの動作率を上げるようにしました。

## Functions 実装コード
以下が検出ロジックの実装です。
環境変数 `SLACK_TOKEN`, `SLACK_CHANNEL_ID`を設定する必要があります。また、監視対象のドメインを変更する必要があります。（ここでは`api.arg.vc`がハードコードされています）

```go
package checkcertificate

import (
	"context"
	"crypto/tls"
	"fmt"
	"net/http"
	"os"
	"time"

	"github.com/GoogleCloudPlatform/functions-framework-go/functions"
	"github.com/slack-go/slack"
)

var JST = time.FixedZone("Asia/tokyo", 9*60*60)

func init() {
	functions.HTTP("CheckCertificates", CheckCertificates)
}

func CheckCertificates(w http.ResponseWriter, r *http.Request) {
	if err := checkCertificates(r.Context()); err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		fmt.Fprintf(w, "checkCertificates failed: %+v", err)
		return
	}
	w.WriteHeader(http.StatusOK)
	fmt.Fprintf(w, "ok")
}

func getExpiration(domain string) (time.Time, error) {
	conn, err := tls.Dial("tcp", fmt.Sprintf("%s:443", domain), nil)
	if err != nil {
		return time.Time{}, fmt.Errorf("tls.Dial failed: %w", err)
	}

	err = conn.VerifyHostname(domain)
	if err != nil {
		return time.Time{}, fmt.Errorf("VerifyHostname failed: %w", err)
	}
	return conn.ConnectionState().PeerCertificates[0].NotAfter, nil
}

func checkCertificates(ctx context.Context) error {
	slackClient := slack.New(os.Getenv("SLACK_TOKEN"))
	domains := []string{
		"api.arg.vc",
	}

	delta := time.Now().AddDate(0, 0, 7)

	for _, domain := range domains {
		expiration, err := getExpiration(domain)
		if err != nil {
			return err
		}

		if delta.UnixNano() >= expiration.UnixNano() {
			_, _, err := slackClient.PostMessageContext(ctx,
				os.Getenv("SLACK_CHANNEL_ID"),
				slack.MsgOptionAttachments(slack.Attachment{
					Title: "あと7日間で証明書が切れるドメインがあります",
					Text:  "証明書を更新してください。",
					Fields: []slack.AttachmentField{
						{
							Title: "ドメイン名",
							Value: domain,
						},
						{
							Title: "有効期限",
							Value: expiration.In(JST).Format(time.RFC3339),
						},
					},
				}))
			if err != nil {
				return err
			}
		}
	}

	return nil
}
```

# 評価
まず、イニシャルコストの観点では、1時間かからずに作り終えることができました。SSL/TLS証明書の有効期限の取得はとても簡単に行うことができるためです。上記ソースコードの`getExpiration`関数を見ていただければわかる通り、Go言語では5行以内で取得処理を実装することができます。
これは嬉しい誤算でした。このプロジェクトを始める前、私は有効期限の取得のためにバイナリをパーズする等の複雑なコードを書かなければいけないのでは、と考えていましたが、実際にはGo言語の標準APIを呼び出すだけで済みました。
また、Cloud SchedulerやCloud Functionsの利用には初期料金はかからないため、イニシャルコストは実装工数のみでした。

次に、ランニングコストの観点では、トータルで0.2USD/月以下に抑えることができました。これは、無視できる程度の費用ではないかと考えます。
また、無料枠に収まっているため、他にCloud SchedulerやCloud Functionsを利用していなければ無料で維持することが可能です。詳細な費用の内訳は以下になります。
* Cloud Schedulerの料金
  * [ジョブあたり0.10USD/月](https://cloud.google.com/scheduler/pricing?hl=ja)
* Cloud Functionsの料金
  * [呼び出しあたり0.0000004USD/回](https://cloud.google.com/functions/pricing)
    * リトライなしで計算すると毎日実行であるため31回。毎回3回のリトライが発生したとしても100回以下。
  * [コンピューティング時間 128 MB/.083 vCPU構成において、0.000000231USD/100ms](https://cloud.google.com/functions/pricing#:~:text=%E3%81%94%E8%A6%A7%E3%81%8F%E3%81%A0%E3%81%95%E3%81%84%E3%80%82-,%E3%82%B3%E3%83%B3%E3%83%94%E3%83%A5%E3%83%BC%E3%83%86%E3%82%A3%E3%83%B3%E3%82%B0%E6%99%82%E9%96%93,-%E3%82%B3%E3%83%B3%E3%83%94%E3%83%A5)
    * 1回エンドポイントの場合で avg 100ms ほど。よって、単に呼び出し回数を乗ずればよい。

# 結論
利用する監視ツールを最低限に抑えるために、SSL/TLS証明書の有効期限の監視を自分で実装するという選択肢も有効であると思いました。
Google Cloud MonitoringのUptime Checksの移行先にお困りの方は採用してみてはいかがでしょうか。