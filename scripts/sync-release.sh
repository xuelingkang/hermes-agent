#!/usr/bin/env bash
#
# sync-release.sh — 把本仓库 <TARGET_BRANCH> 重放到上游最新 release tag 上。
#
# fork 的 <TARGET_BRANCH> = <最新 release tag 的 commit> + 本仓库自己的提交（同步基建）。
# 每次同步 = 把"本仓库自己的提交"重放到新 release 上（git rebase --onto）。
#
# 环境变量：
#   UPSTREAM_URL   上游仓库地址
#   TARGET_BRANCH  要同步的分支（默认 main）
#   SELF           本仓库的 remote 名（默认 origin）
#
set -euo pipefail

UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/NousResearch/hermes-agent.git}"
TARGET_BRANCH="${TARGET_BRANCH:-main}"
SELF="${SELF:-origin}"

log() { printf '%s\n' "$*"; }
die() { printf '✗ %s\n' "$*" >&2; exit 1; }

git rev-parse --git-dir >/dev/null 2>&1 || die "不在 git 仓库内"

# --- 1. 解析上游最新 release ------------------------------------------------
# 不能用 --refs：它会连 ^{} 行一起过滤掉，而 annotated tag 必须解引用成
# commit，否则 push 报 "trying to write non-commit object ... to branch"。
peeled=$(git ls-remote --tags "$UPSTREAM_URL" 'refs/tags/v*' 2>/dev/null \
  | grep '\^{}' | sed 's|refs/tags/||; s|\^{}$||') || true
[ -n "$peeled" ] || die "无法从上游解析 release tag（网络或限流？）"

latest=$(printf '%s\n' "$peeled" | sort -V -k2 | tail -1)
latest_commit=${latest%%$'\t'*}
latest_tag=${latest##*$'\t'}
[ -n "$latest_commit" ] && [ -n "$latest_tag" ] || die "解析最新 release tag 失败"

# --- 2. 定位本地分支与其"底座" ---------------------------------------------
git rev-parse --verify --quiet "refs/heads/${TARGET_BRANCH}" >/dev/null \
  || die "本地没有分支 ${TARGET_BRANCH}"
git checkout -q "$TARGET_BRANCH"

# 底座 = 本分支历史上最近的、被上游 release tag 指向的 commit。
# 用它（而不是 "${TARGET_BRANCH}^"）是为了容忍分支上存在多个本地提交：
# 在 GitHub 网页改一次 workflow 就会多一个提交，用 ^ 会算错底座、丢提交。
base=$(git rev-list "$TARGET_BRANCH" | grep -m1 -xF -f <(printf '%s\n' "$peeled" | cut -f1) || true)
[ -n "$base" ] || die "在 ${TARGET_BRANCH} 的历史里找不到上游 release commit。\
本地提交是否超过了 workflow 里的 fetch-depth？调大它再试。"
# rebase 前记下分支当前值：CI 里它等于远端值，用作 force-with-lease 的期望值
# （语义＝"远端还是我 checkout 时的样子，才允许覆盖"）。
push_expected=$(git rev-parse "$TARGET_BRANCH")

# --- 3. 幂等出口（稳态零网络抓取）------------------------------------------
if [ "$base" = "$latest_commit" ]; then
  log "✓ ${TARGET_BRANCH} 已基于 ${latest_tag}，无需同步"
  exit 0
fi
log "→ 上游最新 release: ${latest_tag} (${latest_commit:0:12})，当前底座 ${base:0:12}"

# --- 4. 只抓那一个 tag -----------------------------------------------------
if ! git cat-file -e "${latest_commit}^{commit}" 2>/dev/null; then
  log "→ 抓取 ${latest_tag}..."
  git fetch --no-tags "$UPSTREAM_URL" "+refs/tags/${latest_tag}:refs/tags/${latest_tag}"
fi
git cat-file -e "${latest_commit}^{commit}" 2>/dev/null \
  || die "本地仍无 ${latest_tag} 的 commit"

# --- 5. 把本仓库自己的提交重放到新 release 上 ------------------------------
own_commits=$(git rev-list --count "${base}..${TARGET_BRANCH}")
log "→ 重放 ${own_commits} 个本地提交到 ${latest_tag}"
git rebase --onto "$latest_tag" "$base" "$TARGET_BRANCH"

# --- 6. 推送（lease 钉住 rebase 前读到的分支值）----------------------------
git push --force-with-lease="${TARGET_BRANCH}:${push_expected}" "$SELF" "$TARGET_BRANCH"

log "✓ ${TARGET_BRANCH} → ${latest_tag} + ${own_commits} 个本地提交"
