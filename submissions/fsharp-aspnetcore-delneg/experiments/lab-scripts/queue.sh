#!/usr/bin/env bash
# Box job queue: runs the lines of $HOME/muclab/queue.txt one at a time (each removed as it starts), so the box is
# never idle and runs never overlap. Append jobs with: echo "<command>" >> $HOME/muclab/queue.txt
# Start: nohup bash queue.sh >> ~/muclab/runs/queue.log 2>&1 &
Q=$HOME/muclab/queue.txt; touch $Q
while true; do
  line=$(head -1 $Q)
  if [ -z "$line" ]; then sed -i '/^$/d' $Q; sleep 10; continue; fi
  sed -i 1d $Q
  echo "== $(date +%H:%M:%S) $line"
  bash -c "$line"
done
