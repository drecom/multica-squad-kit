#!/usr/bin/env bash
# 更新の表（tests/fixtures/host-update-order.tsv）の 1/3。本体は tests/host-order-body.sh。
export HOST_ORDER_SHARD=1/3; source "${0%/*}/host-order-body.sh"
