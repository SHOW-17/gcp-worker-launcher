#!/usr/bin/env bash
# setup-gcp.sh で作った GCP の部品を全部消す（仕組みをやめるときだけ使う）。
# 普段の「使い終わった VM を消す」は workflow の delete で足りるので、これは流さない。
#
#   bash teardown-gcp.sh [PROJECT_ID]
#
# 消す前に「DELETE」と打たせる。無いものは飛ばす。最後に残りを表示する。
set -uo pipefail

GH_REPO="SHOW-17/gcp-worker-launcher"
POOL="github-launcher"
PROVIDER="launcher-main"
SA_NAME="vm-launcher"
ROLE_ID="vmLauncher"
VM_NAME="gcp-worker-s2"
ZONE="us-central1-a"

die() { printf '\n[中止] %s\n' "$*" >&2; exit 1; }

PROJECT_ID="${1:-$(gcloud config get-value project 2>/dev/null || true)}"
[ -n "$PROJECT_ID" ] || die "bash teardown-gcp.sh <PROJECT_ID> の形で ID を渡す"
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)' 2>/dev/null) \
  || die "プロジェクト $PROJECT_ID を読めない"
REPO_ID=$(curl -fsS "https://api.github.com/repos/${GH_REPO}" | jq -r .id 2>/dev/null || true)
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "プロジェクト ${PROJECT_ID} から、VM ${VM_NAME}・SA ${SA_NAME}・ロール ${ROLE_ID}・プール ${POOL} を消す。"
printf '本当に消すなら DELETE と打って Enter: '
read -r ans </dev/tty || die "確認を読めなかった"
[ "$ans" = "DELETE" ] || die "DELETE ではなかったので何もしていない"
gcloud config set project "$PROJECT_ID" >/dev/null 2>&1

echo "== 1. VM"
if gcloud compute instances describe "$VM_NAME" --zone="$ZONE" >/dev/null 2>&1; then
  gcloud compute instances delete "$VM_NAME" --zone="$ZONE" --delete-disks=all --quiet
else echo "無いので飛ばす"; fi

echo "== 2. SA の紐づけ・3. ロールの付与・4. SA"
if gcloud iam service-accounts describe "$SA_EMAIL" >/dev/null 2>&1; then
  if [ -n "$REPO_ID" ] && [ "$REPO_ID" != "null" ]; then
    gcloud iam service-accounts remove-iam-policy-binding "$SA_EMAIL" \
      --role="roles/iam.workloadIdentityUser" \
      --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/attribute.repository_id/${REPO_ID}" \
      >/dev/null 2>&1 || echo "（紐づけは無かった）"
  fi
  gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${SA_EMAIL}" --role="projects/${PROJECT_ID}/roles/${ROLE_ID}" --condition=None \
    >/dev/null 2>&1 || echo "（ロールの付与は無かった）"
  gcloud iam service-accounts delete "$SA_EMAIL" --quiet
else echo "SA が無いので飛ばす"; fi

echo "== 5. カスタムロール"
if [ "$(gcloud iam roles describe "$ROLE_ID" --project="$PROJECT_ID" --format='value(deleted)' 2>/dev/null)" != "True" ] \
   && gcloud iam roles describe "$ROLE_ID" --project="$PROJECT_ID" >/dev/null 2>&1; then
  gcloud iam roles delete "$ROLE_ID" --project="$PROJECT_ID" --quiet >/dev/null
  echo "消した（しばらく「削除済み」で残る。setup-gcp.sh を流し直すと復元して使う）"
else echo "無いので飛ばす"; fi

echo "== 6. プロバイダとプール"
if [ "$(gcloud iam workload-identity-pools describe "$POOL" --location=global --format='value(state)' 2>/dev/null)" = "ACTIVE" ]; then
  gcloud iam workload-identity-pools providers delete "$PROVIDER" --location=global \
    --workload-identity-pool="$POOL" --quiet 2>/dev/null || echo "（プロバイダは無かった）"
  gcloud iam workload-identity-pools delete "$POOL" --location=global --quiet
else echo "無いので飛ばす"; fi

echo "== 7. 残り（VM・ディスクは 0 件、プールは出ないか DELETED、SA は出ないのが正しい）"
echo "-- VM";   gcloud compute instances list --filter="labels.role=gcp-worker" --format='value(name)'
echo "-- ディスク"; gcloud compute disks list --filter="name~^${VM_NAME}" --format='value(name)'
echo "-- プール"; gcloud iam workload-identity-pools list --location=global --show-deleted --format='value(name,state)'
echo "-- SA";   gcloud iam service-accounts list --filter="email:${SA_NAME}@" --format='value(email)'
echo "終わり。GitHub の起動用リポは残してある（やめるなら Settings → Archive）"
