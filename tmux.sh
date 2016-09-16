#!/bin/bash
set -e

stack build

tmux \
    new-session 'stack exec -- iohk --send-for 5 --wait-for 1 --port 10501' \; \
    set remain-on-exit on \; \
    split-window 'stack exec -- iohk --send-for 5 --wait-for 1 --port 10502' \; \
    split-window 'stack exec -- iohk --send-for 5 --wait-for 1 --port 10503' \; \
    split-window 'stack exec -- iohk --send-for 5 --wait-for 1 --port 10504' \; \
    select-layout tiled
