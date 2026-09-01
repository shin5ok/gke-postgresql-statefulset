# =============================================================================
#  GKE 上に PostgreSQL StatefulSet を任意のサイズで構築する
#
#    make db          クラスタ (無ければ作成) + PostgreSQL StatefulSet を構築
#    make db-content  スキーマとダミーデータを投入 (pg_dump 形式から)
#
#  サイズや配置は config.toml で指定する (config.toml.template がひな形)。
# =============================================================================

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

SCRIPTS := ./scripts
CONFIG  := config.toml
TEMPLATE := config.toml.template

# psql などに渡す追加引数:  make psql ARGS='-c "SELECT 1"'
ARGS ?=
# make scale N=3
N ?=

.PHONY: help config show-config cluster credentials db db-content gen-dump db-dump \
        render validate check status psql port-forward logs scale \
        destroy-db destroy-cluster

# -----------------------------------------------------------------------------

help: ## このヘルプを表示する
	@printf '\033[1mGKE PostgreSQL StatefulSet\033[0m\n\n'
	@printf '  \033[1m使い方:\033[0m make <target>\n\n'
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@printf '\n  \033[1m設定:\033[0m %s (無ければ %s から作成)\n' '$(CONFIG)' '$(TEMPLATE)'
	@printf '  \033[2m一時的な上書き: CFG_POSTGRES_REPLICAS=3 CFG_CLUSTER_NUM_NODES=5 make db\033[0m\n\n'

$(CONFIG):
	@cp $(TEMPLATE) $(CONFIG)
	@printf '\033[33m%s を %s から作成しました。必要に応じて編集してください。\033[0m\n' \
	  '$(CONFIG)' '$(TEMPLATE)'

config: $(CONFIG) ## config.toml をテンプレートから作成する

show-config: ## 解決後の設定値をすべて表示する
	@python3 $(SCRIPTS)/config.py show

# -----------------------------------------------------------------------------
#  構築
# -----------------------------------------------------------------------------

cluster: $(CONFIG) ## GKE Standard クラスタを用意する (存在すれば何もしない)
	@$(SCRIPTS)/ensure-cluster.sh

credentials: $(CONFIG) ## kubectl の認証情報を取得する (make cluster と同じ)
	@$(SCRIPTS)/ensure-cluster.sh

db: cluster ## ★ PostgreSQL StatefulSet を構築する (クラスタが無ければ自動作成)
	@$(SCRIPTS)/deploy-db.sh

db-content: $(CONFIG) ## ★ スキーマとダミーデータを投入する (pg_dump からロード)
	@$(SCRIPTS)/load-content.sh

scale: $(CONFIG) ## レプリカ数を変更して再デプロイする  例: make scale N=3
	@test -n "$(N)" || { printf '\033[31mN を指定してください: make scale N=3\033[0m\n'; exit 1; }
	@python3 $(SCRIPTS)/set-config.py postgres replicas "$(N)"
	@$(SCRIPTS)/deploy-db.sh

# -----------------------------------------------------------------------------
#  データ
# -----------------------------------------------------------------------------

gen-dump: $(CONFIG) ## ダミーデータの pg_dump ファイルを再生成する
	@eval "$$(python3 $(SCRIPTS)/config.py sh)"; \
	python3 $(SCRIPTS)/gen-dump.py "$$CFG_CONTENT_DUMP_FILE" \
	  --customers "$$CFG_CONTENT_ROWS_CUSTOMERS" \
	  --products "$$CFG_CONTENT_ROWS_PRODUCTS" \
	  --orders "$$CFG_CONTENT_ROWS_ORDERS" \
	  --seed "$$CFG_CONTENT_SEED"

db-dump: $(CONFIG) ## 稼働中の DB から pg_dump を取り直す
	@$(SCRIPTS)/dump-db.sh

# -----------------------------------------------------------------------------
#  確認 / 操作
# -----------------------------------------------------------------------------

status: $(CONFIG) ## Pod / PVC / Service と接続情報を表示する
	@$(SCRIPTS)/status.sh

psql: $(CONFIG) ## psql を開く  例: make psql ARGS='-c "SELECT count(*) FROM orders;"'
	@$(SCRIPTS)/psql.sh $(ARGS)

port-forward: $(CONFIG) ## localhost:15432 を DB に転送する
	@$(SCRIPTS)/port-forward.sh

logs: $(CONFIG) ## プライマリのログを追う
	@eval "$$(python3 $(SCRIPTS)/config.py sh)"; \
	kubectl --context "$$CFG_KUBE_CONTEXT" -n "$$CFG_POSTGRES_NAMESPACE" \
	  logs -f "$$CFG_POSTGRES_NAME-0" -c postgresql --tail=100

# -----------------------------------------------------------------------------
#  検証 (クラスタ不要)
# -----------------------------------------------------------------------------

render: $(CONFIG) ## マニフェストを build/ に生成するだけ (適用しない)
	@RENDER_ONLY=1 $(SCRIPTS)/deploy-db.sh

validate: $(CONFIG) ## 設定・マニフェスト・スクリプトをオフラインで検証する
	@$(SCRIPTS)/validate.sh

check: validate ## validate の別名

# -----------------------------------------------------------------------------
#  片付け
# -----------------------------------------------------------------------------

destroy-db: $(CONFIG) ## Namespace ごと DB を削除する (クラスタは残す)
	@$(SCRIPTS)/destroy.sh db

destroy-cluster: $(CONFIG) ## GKE クラスタごと削除する
	@$(SCRIPTS)/destroy.sh cluster
