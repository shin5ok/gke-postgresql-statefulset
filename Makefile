# =============================================================================
#  GKE 上に PostgreSQL StatefulSet を任意のサイズで構築する
#  (+ AlloyDB の最小構成と、どちらにも接続できるサンプル Web アプリ)
#
#    make db          クラスタ (無ければ作成) + PostgreSQL StatefulSet を構築
#    make db-content  スキーマとダミーデータを投入 (pg_dump 形式から)
#    make alloydb     AlloyDB (最小構成) + PSC エンドポイントを作成し DB/ユーザを初期化
#    make app         サンプルアプリを GKE にデプロイ ([app] target の DB に接続)
#
#  サイズや配置、アプリの接続先は config.toml で指定する (config.toml.template がひな形)。
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
# make app-target T=alloydb
T ?=

.PHONY: help config show-config validate check render \
        cluster credentials db db-content scale gen-dump db-dump status psql port-forward logs \
        alloydb alloydb-content alloydb-psql alloydb-status \
        app app-image app-target app-status app-port-forward app-logs app-dev \
        destroy-db destroy-cluster destroy-alloydb destroy-app

# -----------------------------------------------------------------------------

help: ## このヘルプを表示する
	@printf '\033[1mGKE PostgreSQL StatefulSet / AlloyDB / サンプルアプリ\033[0m\n\n'
	@printf '  \033[1m使い方:\033[0m make <target>\n'
	@awk 'BEGIN {FS = ":.*?## "} /^##@ / {printf "\n  \033[1m%s\033[0m\n", substr($$0, 5); next} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@printf '\n  \033[1m設定:\033[0m %s (無ければ %s から作成)\n' '$(CONFIG)' '$(TEMPLATE)'
	@printf '  \033[2m一時的な上書き: CFG_POSTGRES_REPLICAS=3 make db / CFG_APP_TARGET=alloydb make app\033[0m\n\n'

$(CONFIG):
	@cp $(TEMPLATE) $(CONFIG)
	@printf '\033[33m%s を %s から作成しました。必要に応じて編集してください。\033[0m\n' \
	  '$(CONFIG)' '$(TEMPLATE)'

##@ 設定 / 検証 (クラスタ不要)

config: $(CONFIG) ## config.toml をテンプレートから作成する

show-config: ## 解決後の設定値をすべて表示する
	@python3 $(SCRIPTS)/config.py show

render: $(CONFIG) ## マニフェストを build/ に生成するだけ (適用しない)
	@RENDER_ONLY=1 $(SCRIPTS)/deploy-db.sh
	@RENDER_ONLY=1 $(SCRIPTS)/deploy-app.sh

validate: $(CONFIG) ## 設定・マニフェスト・スクリプト・アプリをオフラインで検証する
	@$(SCRIPTS)/validate.sh

check: validate ## validate の別名

##@ PostgreSQL (StatefulSet)

cluster: $(CONFIG) ## GKE クラスタを用意する (存在すれば何もしない)
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

gen-dump: $(CONFIG) ## ダミーデータの pg_dump ファイルを再生成する
	@eval "$$(python3 $(SCRIPTS)/config.py sh)"; \
	python3 $(SCRIPTS)/gen-dump.py "$$CFG_CONTENT_DUMP_FILE" \
	  --customers "$$CFG_CONTENT_ROWS_CUSTOMERS" \
	  --products "$$CFG_CONTENT_ROWS_PRODUCTS" \
	  --orders "$$CFG_CONTENT_ROWS_ORDERS" \
	  --seed "$$CFG_CONTENT_SEED"

db-dump: $(CONFIG) ## 稼働中の DB から pg_dump を取り直す
	@$(SCRIPTS)/dump-db.sh

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

##@ AlloyDB (最小構成 + Private Service Connect)

alloydb: cluster ## ★ AlloyDB + PSC エンドポイントを作成し、DB とユーザを初期化する
	@$(SCRIPTS)/ensure-alloydb.sh

alloydb-content: $(CONFIG) ## スキーマとダミーデータを AlloyDB に投入する
	@$(SCRIPTS)/alloydb-content.sh

alloydb-psql: $(CONFIG) ## AlloyDB に psql を開く (一時 Pod 経由)  SUPERUSER=1 / POOLED=1 を付けられる
	@$(SCRIPTS)/alloydb-psql.sh $(ARGS)

alloydb-status: $(CONFIG) ## AlloyDB と PSC エンドポイントの状態・接続情報を表示する
	@$(SCRIPTS)/alloydb-status.sh

##@ サンプルアプリ (app/)

app: cluster app-image ## ★ サンプルアプリを GKE にデプロイする ([app] target の DB に接続)
	@$(SCRIPTS)/deploy-app.sh

app-image: $(CONFIG) ## コンテナイメージをビルドして Artifact Registry に push する (変更が無ければスキップ)
	@$(SCRIPTS)/build-app.sh

app-target: $(CONFIG) ## 接続先を切り替えて再デプロイする  例: make app-target T=alloydb
	@test -n "$(T)" || { printf '\033[31mT を指定してください: make app-target T=alloydb (または T=postgresql)\033[0m\n'; exit 1; }
	@python3 $(SCRIPTS)/set-config.py app target "$(T)"
	@$(MAKE) --no-print-directory app

app-status: $(CONFIG) ## Pod / Service とアクセス方法を表示する
	@$(SCRIPTS)/app-status.sh

app-port-forward: $(CONFIG) ## localhost:8080 をアプリに転送する
	@$(SCRIPTS)/app-port-forward.sh

app-logs: $(CONFIG) ## アプリのログを追う
	@eval "$$(python3 $(SCRIPTS)/config.py sh)"; \
	kubectl --context "$$CFG_KUBE_CONTEXT" -n "$$CFG_APP_NAMESPACE" \
	  logs -f "deployment/$$CFG_APP_NAME" --tail=100

app-dev: $(CONFIG) ## 手元でアプリを起動する (postgresql なら別ターミナルで make port-forward)
	@$(SCRIPTS)/app-dev.sh

##@ 片付け

destroy-db: $(CONFIG) ## Namespace ごと DB を削除する (クラスタは残す)
	@$(SCRIPTS)/destroy.sh db

destroy-cluster: $(CONFIG) ## GKE クラスタごと削除する
	@$(SCRIPTS)/destroy.sh cluster

destroy-alloydb: $(CONFIG) ## AlloyDB クラスタ (インスタンス含む) と PSC エンドポイントを削除する
	@$(SCRIPTS)/destroy.sh alloydb

destroy-app: $(CONFIG) ## サンプルアプリを Namespace ごと削除する (DB は残す)
	@$(SCRIPTS)/destroy.sh app
