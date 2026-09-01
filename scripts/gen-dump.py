#!/usr/bin/env python3
"""ダミーデータ入りの pg_dump 形式 (plain text) ファイルを生成する。

`make db-content` はここで生成された sql/dump.sql を psql に流し込む。
本物の pg_dump 出力と同じ構成 (SET 群 -> DROP -> CREATE TABLE -> COPY ->
制約 / インデックス -> setval) にしてあるので、`make db-dump` で実 DB から
取り直した出力とそのまま差し替えられる。

  usage: gen-dump.py <out> [--customers N] [--products N] [--orders N] [--seed N]
"""
from __future__ import annotations

import argparse
import datetime as dt
import random
import sys
from pathlib import Path

FAMILY = ["Sato", "Suzuki", "Takahashi", "Tanaka", "Ito", "Watanabe", "Yamamoto",
          "Nakamura", "Kobayashi", "Kato", "Smith", "Johnson", "Muller", "Rossi",
          "Dubois", "Garcia", "Chen", "Kim", "Nguyen", "Silva"]
GIVEN = ["Haruto", "Yuto", "Sota", "Yuki", "Hina", "Sakura", "Rin", "Aoi", "Ren",
         "Mio", "Alex", "Emma", "Liam", "Olivia", "Noah", "Ava", "Lucas", "Mia",
         "Ethan", "Sophia"]
COUNTRIES = [("JP", ["Tokyo", "Osaka", "Nagoya", "Fukuoka", "Sapporo", "Kyoto"]),
             ("US", ["Seattle", "Austin", "Boston", "Denver", "Chicago"]),
             ("DE", ["Berlin", "Munich", "Hamburg"]),
             ("SG", ["Singapore"]),
             ("BR", ["Sao Paulo", "Rio de Janeiro"])]
CATEGORIES = [
    ("Laptops", "laptops"), ("Monitors", "monitors"), ("Keyboards", "keyboards"),
    ("Storage", "storage"), ("Networking", "networking"), ("Audio", "audio"),
    ("Cameras", "cameras"), ("Accessories", "accessories"),
]
ADJECTIVES = ["Compact", "Pro", "Ultra", "Lite", "Max", "Studio", "Field", "Rugged",
              "Silent", "Modular", "Wireless", "Portable"]
NOUNS = {
    "laptops": ["Notebook", "Workstation", "Ultrabook"],
    "monitors": ["Display", "Panel", "Screen"],
    "keyboards": ["Keyboard", "Keypad", "Deck"],
    "storage": ["SSD", "NVMe Drive", "HDD", "Card Reader"],
    "networking": ["Router", "Switch", "Access Point", "NIC"],
    "audio": ["Headset", "Speaker", "Microphone", "DAC"],
    "cameras": ["Webcam", "Camcorder", "Action Cam"],
    "accessories": ["Hub", "Stand", "Cable", "Adapter", "Dock"],
}
STATUSES = ["pending", "paid", "shipped", "delivered", "cancelled"]
STATUS_WEIGHTS = [5, 15, 20, 55, 5]

EPOCH = dt.datetime(2024, 1, 1, 0, 0, 0)


def esc(value) -> str:
    """COPY (text 形式) のためのエスケープ。NULL は \\N。"""
    if value is None:
        return r"\N"
    if isinstance(value, bool):
        return "t" if value else "f"
    if isinstance(value, dt.datetime):
        return value.strftime("%Y-%m-%d %H:%M:%S")
    text = str(value)
    return (text.replace("\\", "\\\\").replace("\t", "\\t")
                .replace("\n", "\\n").replace("\r", "\\r"))


def copy_block(out, table: str, columns: list[str], rows) -> int:
    out.write(f"COPY public.{table} ({', '.join(columns)}) FROM stdin;\n")
    count = 0
    for row in rows:
        out.write("\t".join(esc(v) for v in row))
        out.write("\n")
        count += 1
    out.write("\\.\n\n\n")
    return count


HEADER = """--
-- PostgreSQL database dump
--
-- gke-postgresql-statefulset のサンプルスキーマ + ダミーデータ。
-- scripts/gen-dump.py が生成したもので、pg_dump のプレーン形式に合わせてある。
-- 実 DB から取り直す場合は `make db-dump` を使うこと。
--

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

SET default_tablespace = '';
SET default_table_access_method = heap;

--
-- 再実行できるように既存オブジェクトを削除する (pg_dump --clean --if-exists 相当)
--

DROP VIEW IF EXISTS public.order_summary;
DROP TABLE IF EXISTS public.order_items;
DROP TABLE IF EXISTS public.orders;
DROP TABLE IF EXISTS public.products;
DROP TABLE IF EXISTS public.categories;
DROP TABLE IF EXISTS public.customers;


--
-- テーブル定義
--

CREATE TABLE public.customers (
    id integer NOT NULL,
    name text NOT NULL,
    email text NOT NULL,
    country_code character(2) NOT NULL,
    city text NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.categories (
    id integer NOT NULL,
    name text NOT NULL,
    slug text NOT NULL
);

CREATE TABLE public.products (
    id integer NOT NULL,
    category_id integer NOT NULL,
    sku text NOT NULL,
    name text NOT NULL,
    price numeric(10,2) NOT NULL,
    stock integer DEFAULT 0 NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    CONSTRAINT products_price_check CHECK ((price >= (0)::numeric)),
    CONSTRAINT products_stock_check CHECK ((stock >= 0))
);

CREATE TABLE public.orders (
    id integer NOT NULL,
    customer_id integer NOT NULL,
    status text NOT NULL,
    ordered_at timestamp without time zone NOT NULL,
    shipped_at timestamp without time zone,
    total_amount numeric(12,2) DEFAULT 0 NOT NULL,
    CONSTRAINT orders_status_check CHECK ((status = ANY (ARRAY[
        'pending'::text, 'paid'::text, 'shipped'::text,
        'delivered'::text, 'cancelled'::text])))
);

CREATE TABLE public.order_items (
    id integer NOT NULL,
    order_id integer NOT NULL,
    product_id integer NOT NULL,
    quantity integer NOT NULL,
    unit_price numeric(10,2) NOT NULL,
    CONSTRAINT order_items_quantity_check CHECK ((quantity > 0))
);


--
-- シーケンス
--

CREATE SEQUENCE public.customers_id_seq AS integer
    START WITH 1 INCREMENT BY 1 NO MINVALUE NO MAXVALUE CACHE 1;
ALTER SEQUENCE public.customers_id_seq OWNED BY public.customers.id;
ALTER TABLE ONLY public.customers
    ALTER COLUMN id SET DEFAULT nextval('public.customers_id_seq'::regclass);

CREATE SEQUENCE public.categories_id_seq AS integer
    START WITH 1 INCREMENT BY 1 NO MINVALUE NO MAXVALUE CACHE 1;
ALTER SEQUENCE public.categories_id_seq OWNED BY public.categories.id;
ALTER TABLE ONLY public.categories
    ALTER COLUMN id SET DEFAULT nextval('public.categories_id_seq'::regclass);

CREATE SEQUENCE public.products_id_seq AS integer
    START WITH 1 INCREMENT BY 1 NO MINVALUE NO MAXVALUE CACHE 1;
ALTER SEQUENCE public.products_id_seq OWNED BY public.products.id;
ALTER TABLE ONLY public.products
    ALTER COLUMN id SET DEFAULT nextval('public.products_id_seq'::regclass);

CREATE SEQUENCE public.orders_id_seq AS integer
    START WITH 1 INCREMENT BY 1 NO MINVALUE NO MAXVALUE CACHE 1;
ALTER SEQUENCE public.orders_id_seq OWNED BY public.orders.id;
ALTER TABLE ONLY public.orders
    ALTER COLUMN id SET DEFAULT nextval('public.orders_id_seq'::regclass);

CREATE SEQUENCE public.order_items_id_seq AS integer
    START WITH 1 INCREMENT BY 1 NO MINVALUE NO MAXVALUE CACHE 1;
ALTER SEQUENCE public.order_items_id_seq OWNED BY public.order_items.id;
ALTER TABLE ONLY public.order_items
    ALTER COLUMN id SET DEFAULT nextval('public.order_items_id_seq'::regclass);


--
-- データ
--

"""

FOOTER_TEMPLATE = """--
-- シーケンスの現在値
--

SELECT pg_catalog.setval('public.customers_id_seq', {customers}, true);
SELECT pg_catalog.setval('public.categories_id_seq', {categories}, true);
SELECT pg_catalog.setval('public.products_id_seq', {products}, true);
SELECT pg_catalog.setval('public.orders_id_seq', {orders}, true);
SELECT pg_catalog.setval('public.order_items_id_seq', {order_items}, true);


--
-- 主キー / 一意制約
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_email_key UNIQUE (email);
ALTER TABLE ONLY public.categories
    ADD CONSTRAINT categories_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.categories
    ADD CONSTRAINT categories_slug_key UNIQUE (slug);
ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_sku_key UNIQUE (sku);
ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.order_items
    ADD CONSTRAINT order_items_pkey PRIMARY KEY (id);


--
-- インデックス
--

CREATE INDEX customers_country_code_idx ON public.customers USING btree (country_code);
CREATE INDEX products_category_id_idx ON public.products USING btree (category_id);
CREATE INDEX orders_customer_id_idx ON public.orders USING btree (customer_id);
CREATE INDEX orders_ordered_at_idx ON public.orders USING btree (ordered_at DESC);
CREATE INDEX orders_status_idx ON public.orders USING btree (status);
CREATE INDEX order_items_order_id_idx ON public.order_items USING btree (order_id);
CREATE INDEX order_items_product_id_idx ON public.order_items USING btree (product_id);


--
-- 外部キー
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_category_id_fkey FOREIGN KEY (category_id)
    REFERENCES public.categories(id) ON DELETE RESTRICT;
ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_customer_id_fkey FOREIGN KEY (customer_id)
    REFERENCES public.customers(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.order_items
    ADD CONSTRAINT order_items_order_id_fkey FOREIGN KEY (order_id)
    REFERENCES public.orders(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.order_items
    ADD CONSTRAINT order_items_product_id_fkey FOREIGN KEY (product_id)
    REFERENCES public.products(id) ON DELETE RESTRICT;


--
-- ビュー
--

CREATE VIEW public.order_summary AS
 SELECT o.id AS order_id,
    o.ordered_at,
    o.status,
    c.name AS customer_name,
    c.country_code,
    count(oi.id) AS item_count,
    sum(((oi.quantity)::numeric * oi.unit_price)) AS calculated_total,
    o.total_amount
   FROM (((public.orders o
     JOIN public.customers c ON ((c.id = o.customer_id)))
     LEFT JOIN public.order_items oi ON ((oi.order_id = o.id))))
  GROUP BY o.id, o.ordered_at, o.status, c.name, c.country_code, o.total_amount;


ANALYZE public.customers;
ANALYZE public.categories;
ANALYZE public.products;
ANALYZE public.orders;
ANALYZE public.order_items;

--
-- PostgreSQL database dump complete
--
"""


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("out")
    parser.add_argument("--customers", type=int, default=2000)
    parser.add_argument("--products", type=int, default=500)
    parser.add_argument("--orders", type=int, default=8000)
    parser.add_argument("--seed", type=int, default=20260901)
    args = parser.parse_args()

    for label, value in (("--customers", args.customers),
                         ("--products", args.products),
                         ("--orders", args.orders)):
        if value < 0:
            print(f"gen-dump error: {label} は 0 以上です", file=sys.stderr)
            sys.exit(1)
    if args.orders > 0 and (args.customers == 0 or args.products == 0):
        print("gen-dump error: 注文を作るには customers と products が 1 以上必要です",
              file=sys.stderr)
        sys.exit(1)

    rng = random.Random(args.seed)
    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    with out_path.open("w", encoding="utf-8", newline="\n") as out:
        out.write(HEADER)

        # customers
        def customers():
            seen: set[str] = set()
            for i in range(1, args.customers + 1):
                name = f"{rng.choice(GIVEN)} {rng.choice(FAMILY)}"
                country, cities = rng.choice(COUNTRIES)
                local = name.lower().replace(" ", ".")
                email = f"{local}{i}@example.com"
                assert email not in seen
                seen.add(email)
                created = EPOCH + dt.timedelta(seconds=rng.randrange(0, 600 * 86400))
                yield (i, name, email, country, rng.choice(cities), created)

        copy_block(out, "customers",
                   ["id", "name", "email", "country_code", "city", "created_at"],
                   customers())

        copy_block(out, "categories", ["id", "name", "slug"],
                   ((i, name, slug) for i, (name, slug) in enumerate(CATEGORIES, 1)))

        # products
        prices: dict[int, float] = {}

        def products():
            for i in range(1, args.products + 1):
                cat_id = rng.randrange(1, len(CATEGORIES) + 1)
                slug = CATEGORIES[cat_id - 1][1]
                name = f"{rng.choice(ADJECTIVES)} {rng.choice(NOUNS[slug])} {rng.randrange(100, 999)}"
                price = round(rng.uniform(9.99, 2499.0), 2)
                prices[i] = price
                created = EPOCH + dt.timedelta(seconds=rng.randrange(0, 600 * 86400))
                yield (i, cat_id, f"SKU-{slug[:3].upper()}-{i:05d}", name, f"{price:.2f}",
                       rng.randrange(0, 500), rng.random() > 0.05, created)

        copy_block(out, "products",
                   ["id", "category_id", "sku", "name", "price", "stock",
                    "is_active", "created_at"],
                   products())

        # orders と order_items は整合させる必要があるので先に組み立てる
        order_rows = []
        item_rows = []
        item_id = 0
        for order_id in range(1, args.orders + 1):
            customer_id = rng.randrange(1, args.customers + 1)
            ordered_at = EPOCH + dt.timedelta(seconds=rng.randrange(0, 600 * 86400))
            status = rng.choices(STATUSES, weights=STATUS_WEIGHTS, k=1)[0]
            total = 0.0
            for _ in range(rng.randrange(1, 6)):
                item_id += 1
                product_id = rng.randrange(1, args.products + 1)
                quantity = rng.randrange(1, 5)
                unit_price = prices[product_id]
                total += quantity * unit_price
                item_rows.append((item_id, order_id, product_id, quantity,
                                  f"{unit_price:.2f}"))
            shipped_at = None
            if status in ("shipped", "delivered"):
                shipped_at = ordered_at + dt.timedelta(
                    seconds=rng.randrange(3600, 5 * 86400))
            order_rows.append((order_id, customer_id, status, ordered_at, shipped_at,
                               f"{round(total, 2):.2f}"))

        copy_block(out, "orders",
                   ["id", "customer_id", "status", "ordered_at", "shipped_at",
                    "total_amount"],
                   order_rows)
        copy_block(out, "order_items",
                   ["id", "order_id", "product_id", "quantity", "unit_price"],
                   item_rows)

        out.write(FOOTER_TEMPLATE.format(
            customers=max(args.customers, 1),
            categories=len(CATEGORIES),
            products=max(args.products, 1),
            orders=max(args.orders, 1),
            order_items=max(item_id, 1),
        ))

    size_mb = out_path.stat().st_size / 1024 / 1024
    print(f"{out_path}: customers={args.customers} categories={len(CATEGORIES)} "
          f"products={args.products} orders={args.orders} order_items={item_id} "
          f"({size_mb:.1f} MiB)")


if __name__ == "__main__":
    main()
