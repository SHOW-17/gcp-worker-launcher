#!/usr/bin/env bash
# GCP 側の部品（WI プール・プロバイダ・起動専用 SA・カスタムロール）を作り、読み返して合否を出す。
# Cloud Shell で実行する。何度流しても壊れない（あるものは飛ばす・足りないものだけ足す）。
#
#   bash setup-gcp.sh [PROJECT_ID] [-y]
#
#   PROJECT_ID を省くと gcloud の設定 → プロジェクトが 1 つだけならそれ、の順で決める。
#   -y を付けると「このプロジェクトでよいか」の確認を飛ばす。
#
# 秘密は扱わない。鍵（JSON）は作らない。VM は作らない（課金は発生しない）。
set -uo pipefail

GH_REPO="SHOW-17/gcp-worker-launcher"
OWNER_ID_EXPECTED="220997719"
POOL="github-launcher"
PROVIDER="launcher-main"
SA_NAME="vm-launcher"
ROLE_ID="vmLauncher"
WORKFLOW_FILE=".github/workflows/worker-vm.yml"
PERMS="compute.instances.create,compute.instances.delete,compute.instances.get,compute.instances.list,compute.instances.setLabels,compute.disks.create,compute.disks.delete,compute.subnetworks.use,compute.subnetworks.useExternalIp,compute.zoneOperations.get"

say()  { printf '\n== %s\n' "$*"; }
die()  { printf '\n[中止] %s\n' "$*" >&2; exit 1; }

PROJECT_ID=""
ASSUME_YES=0
for a in "$@"; do
  case "$a" in
    -y|--yes) ASSUME_YES=1 ;;
    -*) die "知らないオプション: $a" ;;
    *) PROJECT_ID="$a" ;;
  esac
done

# ---------- (0) 変数 ----------
say "(0) プロジェクトとリポの ID を確かめる"
if [ -z "$PROJECT_ID" ]; then
  PROJECT_ID=$(gcloud config get-value project 2>/dev/null || true)
fi
if [ -z "$PROJECT_ID" ]; then
  mapfile -t _ps < <(gcloud projects list --format='value(projectId)' 2>/dev/null)
  if [ "${#_ps[@]}" -eq 1 ]; then
    PROJECT_ID="${_ps[0]}"
  else
    die "プロジェクトを決められない。bash setup-gcp.sh <PROJECT_ID> の形で ID を渡す（候補: ${_ps[*]:-なし}）"
  fi
fi
PROJECT_NAME=$(gcloud projects describe "$PROJECT_ID" --format='value(name)' 2>/dev/null) \
  || die "プロジェクト $PROJECT_ID を読めない（ID の綴りか、ログイン中のアカウントを確かめる）"
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
echo "PROJECT_ID=$PROJECT_ID（名前: $PROJECT_NAME）"
echo "PROJECT_NUMBER=$PROJECT_NUMBER"
if [ "$ASSUME_YES" -ne 1 ]; then
  printf 'このプロジェクトに作ってよければ Enter、やめるなら Ctrl+C: '
  read -r _ </dev/tty || die "確認を読めなかった（-y を付けて流し直す）"
fi
gcloud config set project "$PROJECT_ID" >/dev/null 2>&1

GH_JSON=$(curl -fsS "https://api.github.com/repos/${GH_REPO}") || die "GitHub の ${GH_REPO} を読めない"
REPO_ID=$(printf '%s' "$GH_JSON" | jq -r .id)
OWNER_ID=$(printf '%s' "$GH_JSON" | jq -r .owner.id)
REPO_FULL=$(printf '%s' "$GH_JSON" | jq -r .full_name)
echo "REPO_ID=$REPO_ID  OWNER_ID=$OWNER_ID  ($REPO_FULL)"
[ "$OWNER_ID" = "$OWNER_ID_EXPECTED" ] || die "持ち主の数値 ID が想定（$OWNER_ID_EXPECTED）と違う: $OWNER_ID"
[ "$REPO_FULL" = "$GH_REPO" ] || die "リポ名が想定と違う: $REPO_FULL"
case "$REPO_ID" in ''|*[!0-9]*) die "リポの数値 ID が取れない: $REPO_ID" ;; esac

SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
ROLE_NAME="projects/${PROJECT_ID}/roles/${ROLE_ID}"
PRINCIPAL="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/attribute.repository_id/${REPO_ID}"
MAPPING="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.repository_id=assertion.repository_id,attribute.repository_owner_id=assertion.repository_owner_id,attribute.ref=assertion.ref,attribute.event_name=assertion.event_name,attribute.workflow_ref=assertion.workflow_ref"
CONDITION="assertion.repository_owner_id=='${OWNER_ID}' && assertion.repository_id=='${REPO_ID}' && assertion.repository=='${GH_REPO}' && assertion.ref=='refs/heads/main' && assertion.event_name=='workflow_dispatch' && assertion.workflow_ref=='${GH_REPO}/${WORKFLOW_FILE}@refs/heads/main'"

# ---------- (1) API ----------
say "(1) 要る API を有効にする（有効なら何も変わらない）"
gcloud services enable iam.googleapis.com iamcredentials.googleapis.com sts.googleapis.com \
  cloudresourcemanager.googleapis.com compute.googleapis.com || die "API の有効化に失敗"

# ---------- (2) プール ----------
say "(2) Workload Identity プール ${POOL}"
pool_state=$(gcloud iam workload-identity-pools describe "$POOL" --location=global --format='value(state)' 2>/dev/null || true)
case "$pool_state" in
  ACTIVE)  echo "あるので飛ばす" ;;
  DELETED) gcloud iam workload-identity-pools undelete "$POOL" --location=global || die "プールの復元に失敗" ;;
  *)       gcloud iam workload-identity-pools create "$POOL" --location=global \
             --display-name="GitHub launcher" || die "プールの作成に失敗" ;;
esac

# ---------- (3) プロバイダ ----------
say "(3) プロバイダ ${PROVIDER}（条件に合うトークンだけ通す）"
prov_state=$(gcloud iam workload-identity-pools providers describe "$PROVIDER" --location=global \
  --workload-identity-pool="$POOL" --format='value(state)' 2>/dev/null || true)
if [ "$prov_state" = "DELETED" ]; then
  gcloud iam workload-identity-pools providers undelete "$PROVIDER" --location=global \
    --workload-identity-pool="$POOL" || die "プロバイダの復元に失敗"
  prov_state=ACTIVE
fi
if [ -n "$prov_state" ]; then
  cur_cond=$(gcloud iam workload-identity-pools providers describe "$PROVIDER" --location=global \
    --workload-identity-pool="$POOL" --format='value(attributeCondition)')
  if [ "$cur_cond" = "$CONDITION" ]; then
    echo "あって条件も同じなので飛ばす"
  else
    echo "あるが条件が違うので、正しい条件に揃える"
    gcloud iam workload-identity-pools providers update-oidc "$PROVIDER" --location=global \
      --workload-identity-pool="$POOL" \
      --issuer-uri="https://token.actions.githubusercontent.com" \
      --attribute-mapping="$MAPPING" --attribute-condition="$CONDITION" || die "プロバイダの更新に失敗"
  fi
else
  gcloud iam workload-identity-pools providers create-oidc "$PROVIDER" --location=global \
    --workload-identity-pool="$POOL" --display-name="gcp-worker-launcher main" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="$MAPPING" --attribute-condition="$CONDITION" || die "プロバイダの作成に失敗"
fi

# ---------- (4) SA ----------
say "(4) 起動専用 SA ${SA_NAME}（鍵は作らない）"
if gcloud iam service-accounts describe "$SA_EMAIL" >/dev/null 2>&1; then
  echo "あるので飛ばす"
else
  gcloud iam service-accounts create "$SA_NAME" \
    --display-name="GCP Worker VM launcher (GitHub Actions only)" || die "SA の作成に失敗"
fi

# ---------- (5) カスタムロール ----------
say "(5) カスタムロール ${ROLE_ID}（VM を作る・消す権限だけ）"
if gcloud iam roles describe "$ROLE_ID" --project="$PROJECT_ID" >/dev/null 2>&1; then
  if [ "$(gcloud iam roles describe "$ROLE_ID" --project="$PROJECT_ID" --format='value(deleted)')" = "True" ]; then
    gcloud iam roles undelete "$ROLE_ID" --project="$PROJECT_ID" >/dev/null || die "ロールの復元に失敗"
  fi
  # 足りない分だけ足す（後から足した権限は消さない）
  gcloud iam roles update "$ROLE_ID" --project="$PROJECT_ID" --add-permissions="$PERMS" --quiet >/dev/null \
    || die "ロールの更新に失敗"
  echo "あるので、決めた権限が入っていることだけ揃えた"
else
  gcloud iam roles create "$ROLE_ID" --project="$PROJECT_ID" \
    --title="GCP Worker VM launcher" --stage=GA --permissions="$PERMS" || die "ロールの作成に失敗"
fi

# 作ったばかりの SA は数秒見えないことがあるので、付与は少し待って繰り返す
retry() { local i; for i in 1 2 3 4 5 6; do "$@" >/dev/null && return 0; sleep 10; done; return 1; }

# ---------- (6) SA にロール ----------
say "(6) SA にカスタムロールを付ける（付いていれば何も変わらない）"
retry gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SA_EMAIL}" --role="$ROLE_NAME" --condition=None \
  || die "ロールの付与に失敗"
echo "OK"

# ---------- (7) プロバイダ → SA ----------
say "(7) 起動用リポ（数値 ID）からだけ SA を使えるようにする"
retry gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --role="roles/iam.workloadIdentityUser" --member="$PRINCIPAL" \
  || die "SA の紐づけに失敗"
echo "OK"

# ---------- §3 読み返し ----------
say "読み返し（R1〜R6）"
fails=0
check() { # $1=番号 $2=説明 $3=0なら合格
  if [ "$3" -eq 0 ]; then printf '  [合格] %s %s\n' "$1" "$2"; else printf '  [不合格] %s %s\n' "$1" "$2"; fails=$((fails+1)); fi
}

s=$(gcloud iam workload-identity-pools describe "$POOL" --location=global --format='value(state)' 2>/dev/null)
[ "$s" = "ACTIVE" ]; rc=$?
check R1 "プールが ACTIVE（実際: ${s:-無し}）" $rc

pj=$(gcloud iam workload-identity-pools providers describe "$PROVIDER" --location=global \
  --workload-identity-pool="$POOL" --format=json 2>/dev/null || echo '{}')
ps=$(printf '%s' "$pj" | jq -r '.state // ""')
pi=$(printf '%s' "$pj" | jq -r '.oidc.issuerUri // ""')
pc=$(printf '%s' "$pj" | jq -r '.attributeCondition // ""')
[ "$ps" = "ACTIVE" ] && [ "$pi" = "https://token.actions.githubusercontent.com" ] && [ "$pc" = "$CONDITION" ]; rc=$?
check R2 "プロバイダが ACTIVE・発行元が GitHub・条件が持ち主/リポ/main/workflow_dispatch/workflow ファイルの全一致" $rc

perms_now=$(gcloud iam roles describe "$ROLE_ID" --project="$PROJECT_ID" --format=json 2>/dev/null \
  | jq -r '(.includedPermissions // [])[]' | sort)
stage=$(gcloud iam roles describe "$ROLE_ID" --project="$PROJECT_ID" --format='value(stage)' 2>/dev/null)
missing=$(comm -23 <(tr ',' '\n' <<<"$PERMS" | sort) <(printf '%s\n' "$perms_now"))
extra=$(comm -13 <(tr ',' '\n' <<<"$PERMS" | sort) <(printf '%s\n' "$perms_now"))
[ "$stage" = "GA" ] && [ -z "$missing" ]; rc=$?
check R3 "ロールが GA で決めた 10 個の権限を持つ（不足: ${missing:-なし}）" $rc
[ -n "$extra" ] && printf '         後から足した権限: %s\n' "$(echo $extra)"

roles_now=$(gcloud projects get-iam-policy "$PROJECT_ID" --flatten="bindings[].members" \
  --filter="bindings.members:serviceAccount:${SA_EMAIL}" --format='value(bindings.role)' 2>/dev/null | sort -u)
[ "$roles_now" = "$ROLE_NAME" ]; rc=$?
check R4 "SA に付いたロールが ${ROLE_ID} だけ（実際: $(echo ${roles_now:-無し})）" $rc

sa_pol=$(gcloud iam service-accounts get-iam-policy "$SA_EMAIL" --format=json 2>/dev/null || echo '{}')
sa_members=$(printf '%s' "$sa_pol" | jq -r '(.bindings // [])[] | .role + " " + (.members[])' | sort -u)
[ "$sa_members" = "roles/iam.workloadIdentityUser ${PRINCIPAL}" ]; rc=$?
check R5 "SA を使えるのが起動用リポ（repository_id=${REPO_ID}）だけ" $rc
[ "$sa_members" = "roles/iam.workloadIdentityUser ${PRINCIPAL}" ] || printf '         実際:\n%s\n' "$sa_members"

nkeys=$(gcloud iam service-accounts keys list --iam-account="$SA_EMAIL" --managed-by=user \
  --format='value(name)' 2>/dev/null | wc -l)
[ "$nkeys" -eq 0 ]; rc=$?
check R6 "SA の鍵（自分で作るもの）が 0 件（実際: ${nkeys} 件）" $rc

echo
if [ "$fails" -eq 0 ]; then
  echo "■ 合否: 合格（R1〜R6 すべて合格）"
else
  echo "■ 合否: 不合格 ${fails} 件。この画面の出力を全部コピーして PM に戻す"
fi

say "workflow の env に写す 2 行（秘密ではない）"
echo "  PROJECT_ID: ${PROJECT_ID}"
echo "  PROJECT_NUMBER: \"${PROJECT_NUMBER}\""
[ "$fails" -eq 0 ]
