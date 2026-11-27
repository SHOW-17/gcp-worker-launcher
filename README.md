# gcp-worker-launcher

GCP Worker の VM を作る・消すだけの workflow。秘密は置いていません。

- GitHub Actions から鍵なし（Workload Identity Federation / OIDC）で Google Cloud に入り、VM を 1 台作る・消すだけ
- VM の設定は workflow に直書き。起動時の入力は `create` / `delete` の 2 択だけ
- `main` は Ruleset で保護（直接 push・force push・削除を拒否）

## ファイル

| ファイル | 中身 |
|---|---|
| `setup-gcp.sh` | Cloud Shell で 1 回流す。GCP 側の部品（WI プール・プロバイダ・起動専用 SA・カスタムロール）を作り、読み返して合否を表示する。何度流しても壊れない。VM は作らない |
| `teardown-gcp.sh` | 仕組みをやめるときに部品を全部消す（`DELETE` と打つまで何もしない） |

## 使い方（Cloud Shell）

```bash
[ -d ~/gcp-worker-launcher ] || git clone -q https://github.com/SHOW-17/gcp-worker-launcher.git ~/gcp-worker-launcher; cd ~/gcp-worker-launcher && git fetch -q origin && git checkout -q origin/main && bash setup-gcp.sh
```

プロジェクト ID は引数で渡せる（`bash setup-gcp.sh <PROJECT_ID>`）。省くと `gcloud config get-value project` を使う。
