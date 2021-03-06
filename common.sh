#!/bin/bash
if [ "$DEBUG" != defined ]; then
  now() {
    date +'%s%N'
  }
  start=$(now)
  temp="${temp:-/tmp/spelling}"
  export temp
  if [ -n "$DEBUG" ]; then
    set -x
    begin_group() {
      echo "::group::$1"
    }
    end_group() {
      echo '::end_group::'
    }
  else
    begin_group() {
      echo "(...$1...)"
    }
    end_group() {
      :
    }
    DEBUG=defined
  fi
fi
