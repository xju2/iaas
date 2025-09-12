#!/bin/bash

# Usage: ./interactive_continous.sh interactive_config.json

# set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <config.json>"
  exit 1
fi

CONFIG_FILE="$1"

read_json() {
  jq -r "$1" "$CONFIG_FILE"
}

read_json_array() {
  jq -r "$1 | @sh" "$CONFIG_FILE"
}

TOTAL_HOURS=$(read_json '.total_hours')
TIME_PER_JOB_HOURS=$(read_json '.time_per_job_hours // 4')
BUFFER_SECONDS=$(read_json '.buffer_seconds // 300')
WAIT_TIMEOUT_SECONDS=$(read_json '.wait_timeout_seconds // 300')
RETRY_DELAY=$(read_json '.retry_delay // 60')
SRUN_RETRIES=$(read_json '.srun_retries // 10')
EMAIL=$(read_json '.email // empty')
MAIL_TYPE=$(read_json '.mail_type // "END,FAIL"')
JOB_NAME=$(read_json '.job_name // "Fundra"')

# Read arrays
eval "SRUN_ARGS=($(read_json_array '.srun_command'))"
eval "TRAIN_ARGS=($(read_json_array '.train_command'))"

# Add email options to srun if provided
if [[ -n "$EMAIL" ]]; then
  SRUN_ARGS+=("--mail-type=$MAIL_TYPE" "--mail-user=$EMAIL")
fi
if [[ -n "$JOB_NAME" ]]; then
  SRUN_ARGS+=("-J" "$JOB_NAME")
fi

TOTAL_SECONDS=$(( TOTAL_HOURS * 3600 ))
REMAINING=$TOTAL_SECONDS
TIME_PER_JOB_SECONDS=$(( TIME_PER_JOB_HOURS * 3600 ))
EFFECTIVE_JOB_SECONDS=$(( TIME_PER_JOB_SECONDS - BUFFER_SECONDS ))

echo "[INFO] Starting requeue script from config: $CONFIG_FILE"
echo "[INFO] Notification email: $EMAIL (on: $MAIL_TYPE)"
echo "[INFO] Total allowed time: $TOTAL_HOURS h, per job: $TIME_PER_JOB_HOURS h, buffer: $BUFFER_SECONDS s"

START_TIME=$(date +%s)
RUN_INDEX=0

LOGFILE="logs/slurm_logs/${JOB_NAME}/run_${RUN_INDEX}.log"
mkdir -p "$(dirname "$LOGFILE")"

while true; do
  NOW=$(date +%s)
  ELAPSED=$(( NOW - START_TIME ))

  if (( ELAPSED >= TOTAL_SECONDS )); then
    echo "[INFO] Total time limit reached. Exiting."
    break
  fi

  RUN_TIME=$(( EFFECTIVE_JOB_SECONDS < REMAINING ? EFFECTIVE_JOB_SECONDS : REMAINING ))

  echo "[INFO] Requesting session for $(( RUN_TIME / 60 )) minutes (Run #$((RUN_INDEX + 1)))"

  LOGFILE="logs/slurm_logs/${JOB_NAME}/run_${RUN_INDEX}.log"
  echo "[INFO] Logging to $LOGFILE"

  "${SRUN_ARGS[@]}" /bin/bash -c "${TRAIN_ARGS[*]}" >& "$LOGFILE" &
  SRUN_PID=$!

  # wait a moment to ensure srun has submitted the job
  sleep 5

  # Look up the job ID by job name and user
  JOB_ID=""
  while [[ -z "$JOB_ID" ]]; do
    JOB_ID=$(squeue -u "$USER" -o "%i %j" -h | awk -v name="$JOB_NAME" '$2 == name {print $1}' | tail -n 1)
    if [[ -z "$JOB_ID" ]]; then
      echo "Waiting for job submission to register..."
      sleep 2
    fi
  done

  # Pool until job is running
  echo "Polling for job $JOB_ID ($JOB_NAME) to start..."
  while true; do
    STATE=$(squeue -j "$JOB_ID" -h -o "%T")
    if [[ "$STATE" == "RUNNING" ]]; then
      echo "Job $JOB_ID is RUNNING."
      break
    elif [[ -z "$STATE" ]]; then
      echo "Job $JOB_ID is no longer in the queue (exited or failed)."
      break
    else
      echo "Current state: $STATE. Waiting..."
      sleep 10
    fi
  done

  # start the timer for the jobs and check if it finishes.
  START_JOB_TIME=$(date +%s)
  wait "$SRUN_PID"
  EXIT_STATUS=$?
  END_JOB_TIME=$(date +%s)

  if [[ $EXIT_STATUS -ne 0 ]]; then
    echo "[ERROR] Job $JOB_ID failed with exit status $EXIT_STATUS. Retrying..."
  else
    echo "[INFO] Job $JOB_ID completed successfully."
  fi

  ELAPSED=$(( END_JOB_TIME - START_JOB_TIME ))
  # Check if the job ran longer than expected
  # if the ELAPSED time is less than one hour, we assume it failed and exit.
  if [[ $ELAPSED -lt 3600 ]]; then
    echo "[ERROR] Job $JOB_ID ran for only $(( ELAPSED / 60 )) minutes, which is less than the expected time. Exiting."
    break
  fi

  REMAINING=$(( REMAINING - ELAPSED ))

  RUN_INDEX=$((RUN_INDEX + 1))
done

echo "[INFO] All scheduled runs completed."
