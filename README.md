# IOHK test

## Usage

First of all, since the list of nodes is hardcoded, please modify the `src/Main.hs` file at line 23 and replace the current nodes with your cluster.

Compile the program by running `stack build` (requires [stack](https://haskellstack.org)), and run it with `stack exec -- iohk`.

The following arguments are available:

```
Usage: iohk --send-for DURATION --wait-for DURATION [--with-seed SEED]
            [--port PORT]

Available options:
  -h,--help                Show this help text
  --send-for DURATION      How many seconds the system sends messages
  --wait-for DURATION      Length of the grace period in second
  --with-seed SEED         Random seed to use (default: 0)
  --port PORT              Port to bind to (default: "10501")
```

Finally, the `tmux.sh` scripts uses tmux to run 4 instances of the program on splitted windows, to make it easy to run the application of localhost.

## Remarks

This first approach uses Lamport's timestamping, as described in *Time, Clocks, and the Ordering of Events in a Distributed System* (can be found in p558-lamport.pdf). This algorithm offer the nodes a way to agree on the order of the messages. However, this approach offers no way to ensure every node gets every message ; since some messages are dropped even on a "localhost cluster", that means the nodes never agree on a final result.

I started working on a second approach which uses the Raft consensus algorithm.