#!/bin/bash
# This CI acceptance test is based on:
# https://github.com/jsoref/spelling/tree/04648bdc63723e5cdf5cbeaff2225a462807abc8
# It is conceptually `f` which runs `w` (spelling-unknown-word-splitter)
# plus `fchurn` which uses `dn` mostly rolled together.
set -e
export spellchecker=${spellchecker:-/app}
. "$spellchecker/common.sh"

main() {
  GITHUB_TOKEN=${GITHUB_TOKEN:-$INPUT_GITHUB_TOKEN}
  if [ -z "$GITHUB_EVENT_PATH" ] || [ ! -e "$GITHUB_EVENT_PATH" ]; then
    GITHUB_EVENT_PATH=/dev/null
  fi
  case "$GITHUB_EVENT_NAME" in
    schedule)
      exec "$spellchecker/check-pull-requests.sh"
      ;;
  esac
}

command_v() {
  command -v "$1" >/dev/null 2>/dev/null
}

define_variables() {
  bucket=${INPUT_BUCKET:-$bucket}
  project=${INPUT_PROJECT:-$project}

  dict="$spellchecker/words"
  patterns="$spellchecker/patterns.txt"
  excludes="$spellchecker/excludes.txt"
  excludes_path="$temp/excludes.txt"
  only="$spellchecker/only.txt"
  only_path="$temp/only.txt"
  dictionary_path="$temp/dictionary.txt"
  allow_path="$temp/allow.txt"
  reject_path="$temp/reject.txt"
  expect_path="$temp/expect.words.txt"
  excludelist_path="$temp/excludes.txt"
  patterns_path="$temp/patterns.txt"
  advice_path="$temp/advice.txt"
  word_splitter="$spellchecker/spelling-unknown-word-splitter.pl"
  run_output="$temp/unknown.words.txt"
  run_files="$temp/reporter-input.txt"
  run_warnings="$temp/matcher.txt"
  tokens_file="$temp/tokens.txt"
}

sort_unique() {
  sort -u -f "$@" | perl -ne 'next unless /./; print'
}

project_file_path() {
  echo $bucket/$project/$1.txt
}

check_pattern_file() {
  perl -i -e 'while (<>) {
    next if /^#/;
    if (eval {qr/$_/}) {
      print;
    } else {
      $@ =~ s/(.*?)\n.*/$1/m;
      chomp $@;
      my $err = $@;
      $err =~ s{^.*? in regex; marked by <-- HERE in m/(.*) <-- HERE.*$}{$1};
      my $start = length $err;
      print STDERR "$ARGV: line $., columns $start-$start, Warning - bad regex (bad-regex)\n$@\n";
      print "^\$\n";
    }
  }' $1
}

check_for_newline_at_eof() {
  maybe_missing_eol="$1"
  if [ $(tail -1 "$maybe_missing_eol" | wc -l) -eq 0 ]; then
    line=$(( $(cat "$maybe_missing_eol" | wc -l) + 1 ))
    start=$(tail -1 "$maybe_missing_eol" | wc -c)
    stop=$(( $start + 1 ))
    echo "$maybe_missing_eol: line $line, columns $start-$stop, Warning - no newline at eof (no-newline-at-eof)" >&2
    echo >> "$maybe_missing_eol"
  fi
}

cleanup_file() {
  maybe_bad="$1"
  type="$2"
  case "$type" in
    patterns|excludes|only)
      check_pattern_file "$1"
    ;;
  esac
  check_for_newline_at_eof "$1"
}

get_project_files() {
  file=$1
  dest=$2
  if [ ! -e "$dest" ] && [ -n "$bucket" ] && [ -n "$project" ]; then
    from=$(project_file_path $file)
    case "$from" in
      .*)
        append_to="$from"
        append_to_generated=""
        if [ -f "$from" ]; then
          echo "Retrieving $file from $from"
          cleanup_file "$from" "$file"
          cp "$from" $dest
          from_expanded="$from"
        else
          if [ ! -e "$from" ]; then
            ext=$(echo "$from" | sed -e 's/^.*\.//')
            from=$(echo $from | sed -e "s/\.$ext$//")
          fi
          if [ -d "$from" ]; then
            from_expanded=$(ls $from/*$ext |sort)
            append_to=$from/${GITHUB_SHA:-$(date +%Y%M%d%H%m%S)}.$ext
            append_to_generated=new
            touch $dest
            for item in $from_expanded; do
              if [ -s $item ]; then
                cleanup_file "$item" "$file"
                cat "$item" >> $dest
              fi
            done
            from="$from/$(basename "$from")".$ext
            echo "Retrieving $file from $from_expanded"
          fi
        fi;;
      ssh://git@*|git@*)
        (
          echo "Retrieving $file from $from"
          cd $temp
          repo=$(echo "$bucket" | perl -pne 's#(?:ssh://|)git\@github.com[:/]([^/]*)/(.*.git)#https://github.com/$1/$2#')
          [ -d metadata ] || git clone --depth 1 $repo --single-branch --branch $project metadata
          cleanup_file "metadata/$file.txt" "$file"
          cp metadata/$file.txt $dest 2> /dev/null || touch $dest
        );;
      gs://*)
        echo "Retrieving $file from $from"
        gsutil cp -Z $from $dest >/dev/null 2>/dev/null || touch $dest
        cleanup_file "$dest" "$file"
        ;;
      *://*)
        echo "Retrieving $file from $from"
        download "$from" "$dest" || touch $dest
        cleanup_file "$dest" "$file"
        ;;
    esac
  fi
}
get_project_files_deprecated() {
  # "preferred" "deprecated" "path"
  if [ ! -s "$3" ]; then
    save_append_to="$append_to"
    get_project_files "$2" "$3"
    if [ -s "$3" ]; then
      example=$(for file in $from_expanded; do echo $file; done|head -1)
      if [ $(basename $(dirname $example)) = "$2" ]; then
        note=" directory"
      else
        note=""
      fi
      echo "::warning file=$example::deprecation: please rename '$2'$note to '$1'"
    else
      append_to="$save_append_to"
    fi
  fi
}

download() {
  curl -L -s "$1" -o "$2" -f
  exit_value=$?
  if [ $exit_value = 0 ]; then
    echo "Downloaded $1 (to $2)" >&2
  fi
  return $exit_value
}

download_or_quit_with_error() {
  exit_code=$(mktemp)
  download "$1" "$2" || (
    echo $? > $exit_code
    echo "Could not download $1 (to $2)" >&2
  )
  if [ -s $exit_code ]; then
    exit_value=$(cat $exit_code)
    rm $exit_code
    quit $exit_value
  fi
}

set_up_tools() {
  apps=""
  add_app() {
    if ! command_v $1; then
      apps="$apps $1"
    fi
  }
  add_app curl
  add_app git
  add_app parallel
  if [ -n "$apps" ]; then
    if command_v apt-get; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get update &&
      apt-get install --no-install-recommends -y $apps
    elif command_v brew; then
      brew install $apps
    else
      echo missing $apps -- things will fail >&2
    fi
  fi
  if ! command_v jq || jq --version | perl -ne 'exit 0 unless s/^jq-//;exit 1 if /^(?:[2-9]|1\d|1\.(?:[6-9]|1\d+))/; exit 0'; then
    jq_url=https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64
    spellchecker_bin="$spellchecker/bin"
    jq_bin="$spellchecker_bin/jq"
    mkdir -p $spellchecker_bin
    download_or_quit_with_error "$jq_url" "$jq_bin"
    chmod 0755 "$jq_bin"
    PATH=$spellchecker_bin:$PATH
  fi
}

set_up_files() {
  mkdir -p .git
  cp $spellchecker/reporter.json .git/
  echo "::add-matcher::.git/reporter.json"
  get_project_files expect $expect_path
  get_project_files_deprecated expect whitelist $expect_path
  expect_files=$from_expanded
  expect_file=$from
  new_expect_file=$append_to
  new_expect_file_new=$append_to_generated
  get_project_files excludes $excludelist_path
  if [ -s "$excludes_path" ]; then
    cp "$excludes_path" "$excludes"
  fi
  get_project_files dictionary $dictionary_path
  if [ -s "$dictionary_path" ]; then
    cp "$dictionary_path" "$dict"
  fi
  if [ ! -s "$dict" ]; then
    if [ -z "$DICTIONARY_VERSION" ]; then
      DICTIONARY_VERSION=20200211
    fi
    if [ -z "$DICTIONARY_URL" ]; then
      DICTIONARY_URL='https://raw.githubusercontent.com/check-spelling/check-spelling/dictionary-$DICTIONARY_VERSION/dict.txt'
    fi
    eval download_or_quit_with_error "$DICTIONARY_URL" "$dict"
  fi
  get_project_files allow $allow_path
  if [ -s "$allow_path" ]; then
    cat "$allow_path" >> "$dict"
  fi
  get_project_files reject $reject_path
  if [ -s "$reject_path" ]; then
    dictionary_temp=$(mktemp)
    if grep_v_string '^('$(echo $(cat "$reject_path")|tr " " '|')')$' < "$dict" > $dictionary_temp; then
      cat $dictionary_temp > "$dict"
    fi
  fi
  get_project_files only $only_path
  if [ -s "$only_path" ]; then
    cp "$only_path" "$only"
  fi
  get_project_files patterns $patterns_path
  if [ -s "$patterns_path" ]; then
    cp "$patterns_path" "$patterns"
  fi
  get_project_files advice $advice_path

  if [ -n "$debug" ]; then
    echo "Clean up from previous run"
  fi
  rm -f "$run_output"
}

welcome() {
  echo "Checking spelling..."
  if [ -n "$DEBUG" ]; then
    begin_group 'Excluded paths'
    if [ -e "$excludes" ]; then
      echo 'Excluded paths:'
      cat "$excludes"
    else
      echo 'No excluded paths file'
    fi
    end_group
    begin_group 'Only paths restriction'
    if [ -e "$only" ]; then
      echo 'Only paths restriction:'
      cat "$only"
    else
      echo 'No only paths restriction file'
    fi
    end_group
  fi
}

xargs_zero() {
  if command_v parallel; then
    parallel --no-notice --no-run-if-empty -0 -n1 "$@"
  elif [ $(uname) = "Linux" ]; then
    xargs --no-run-if-empty -0 -n1 "$@"
  else
    arguments="$*" "$spellchecker/xargs_zero"
  fi
}

run_spell_check() {
  begin_group 'Spell check'
  (
    git 'ls-files' -z 2> /dev/null |\
    "$spellchecker/exclude.pl") |\
  xargs_zero "$word_splitter" |\
  "$word_splitter" |\
  perl -p -n -e 's/ \(.*//' > "$run_output"
  word_splitter_status="${PIPESTATUS[2]} ${PIPESTATUS[3]}"
  end_group
  if [ "$word_splitter_status" != '0 0' ]; then
    echo "$word_splitter failed ($word_splitter_status)"
    exit 2
  fi
}

printDetails() {
  echo ''
  echo 'If you are ok with the output of this run, you will need to'
}

relative_note() {
  if [ -n "$bucket" ] && [ -n "$project" ]; then
    from=$(project_file_path $file)
    case "$from" in
      .*)
        ;;
      ssh://git@*|git@*|gs://|*://*)
        echo '(They can be run anywhere with permissions to update the bucket.)';;
    esac
  fi
}
to_retrieve_expect() {
  expect_file=expect.txt
  case "$bucket" in
    '')
      echo '# no bucket defined -- you can specify one per the README.md using the file defined below:';;
    ssh://git@*|git@*)
      echo "git clone --depth 1 $bucket --single-branch --branch $project metadata; cp metadata/expect.txt .";;
    gs://*)
      echo gsutil cp -Z $(project_file_path expect) expect.txt;;
    *://*)
      echo curl -L -s "$(project_file_path expect)" -o expect.txt;;
  esac
}
to_publish_expect() {
  case "$bucket" in
    '')
      echo "# no bucket defined -- copy $1 to a bucket and configure it per the README.md";;
    ssh://git@*|git@*)
      echo "cp $1 metadata/expect.txt; (cd metadata; git commit expect.txt -m 'Updating expect'; git push)";;
    gs://*)
      echo gsutil cp -Z $1 $(project_file_path expect);;
    *://*)
      echo "# command to publish $1 is not known. URL: $(project_file_path expect)";;
    *)
      if [ "$2" = new ]; then
        cmd="git add $bucket/$project || echo '... you want to ensure $1 is added to your repository...'"
        case $(realpath --relative-base="$bucket" "$1") in
          /*)
            cmd="cp $1 $(project_file_path expect); $cmd";;
        esac
        echo "$cmd"
      fi
      ;;
  esac
}

spelling_warning() {
  OUTPUT="#### $1:
"
  spelling_body "$2" "$3"
  post_commit_comment
}
spelling_info() {
  if [ -z "$2" ]; then
    out="$1"
  else
    out="$1

$2"
  fi
  spelling_body "$out" "$3"
  if [ -n "$VERBOSE" ]; then
    post_commit_comment
  else
    echo "$OUTPUT"
  fi
}
spelling_body() {
  err="$2"
  if [ -n "$OUTPUT" ]; then
    header="$OUTPUT

"
  else
    header=""
  fi
  if [ -z "$err" ]; then
    OUTPUT="$header$1"
  else
    OUTPUT="$header$1

<details><summary>To accept these changes, run the following commands</summary>
"$(relative_note)"

"'```'"
$err
"'```
</details>'
    if [ -s "$advice_path" ]; then
      OUTPUT="$OUTPUT

`cat "$advice_path"`
"
    fi
  fi
}
bullet_words() {
  echo "$1" > "$tokens_file"
  perl -pne 's/^(.)/* $1/' "$tokens_file"
  rm -f "$run_warnings"
  export tokens_file
  head=$(cat $GITHUB_EVENT_PATH | jq -r '.pull_request.head.sha' -M)
  if [ -z "$head" ] || [ "$head" = "null" ]; then
    head=${GITHUB_SHA:-HEAD}
  fi
  base=$(cat $GITHUB_EVENT_PATH | jq -r '.pull_request.base.sha // .before // "HEAD^"' -M)
  if [ -z "$base" ]; then
    base=$head^
  fi
  if ! git show $base 2>/dev/null >/dev/null; then
    base=$head^
  fi
  if [ -z "$ONLY_REPORT_HEAD" ] && !git show $base 2>/dev/null >/dev/null; then
    ONLY_REPORT_HEAD=1
  fi
  if [ -z "$ONLY_REPORT_HEAD" ]; then
    rm -f "$run_files"
    (
    export with_blame=1
    export HEAD=$head;
    git diff-tree \
      --no-commit-id \
      --name-only \
      --diff-filter=d \
      -r $base..$head \
      -z 2> /dev/null |
    "$spellchecker/exclude.pl" |
    xargs_zero "$spellchecker/porcelain.pl" > "$run_files"
    $spellchecker/reporter.pl < "$run_files" > "$run_warnings.raw"
    )
    rm -f "$run_files"
  else
    git ls-files -z 2> /dev/null |
    "$spellchecker/exclude.pl" | xargs_zero $spellchecker/reporter.pl > "$run_warnings.raw"
  fi
  if [ -s "$run_warnings.raw" ]; then
    (
      end_group
      begin_group 'Misspellings'
      cat "$run_warnings.raw"
    ) > "$run_warnings"
    rm -f "$run_warnings.raw"
  fi
  rm -f "$tokens_file"
}

quit() {
  echo "::remove-matcher owner=check-spelling::"
  if [ -n "$junit" ]; then
    exit
  fi
  exit $1
}

body_to_payload() {
  BODY="$1"
  PAYLOAD=$(mktemp)
  echo '{}' | jq --rawfile body "$BODY" '.body = $body' > $PAYLOAD
  cat $PAYLOAD >&2
  echo "$PAYLOAD"
}

comment() {
  comments_url="$1"
  payload="$2"
  if [ -n "$payload" ]; then
    payload="--data @$payload"
  fi
  curl -L -s -S \
    $method \
    -H "Authorization: token $GITHUB_TOKEN" \
    --header "Content-Type: application/json" \
    -H 'Accept: application/vnd.github.comfort-fade-preview+json' \
    $payload \
    "$comments_url"
}

post_commit_comment() {
  if [ -e "$run_warnings" ]; then
    cat "$run_warnings"
    rm -f "$run_warnings"
  fi
  if [ -n "$OUTPUT" ]; then
    echo "Preparing a comment"
    if [ -n "$GITHUB_EVENT_PATH" ]; then
      case "$GITHUB_EVENT_NAME" in
        pull_request)
          COMMENTS_URL=$(cat $GITHUB_EVENT_PATH | jq -r .pull_request.comments_url);;
        push)
          COMMENTS_URL=$(cat $GITHUB_EVENT_PATH | jq -r .repository.commits_url | perl -pne 's#\{/sha}#/'$GITHUB_SHA'/comments#');;
      esac
    fi
    if [ -n "$COMMENTS_URL" ] && [ -z "${COMMENTS_URL##*:*}" ]; then
      BODY=$(mktemp)
      echo "$OUTPUT" > $BODY
      body_to_payload $BODY
      rm -f $BODY
      echo $COMMENTS_URL
      comment "$COMMENTS_URL" "$PAYLOAD"
    else
      echo "$OUTPUT"
    fi
  fi
}

report_first_run() {
  if [ ! -s "$run_output" ]; then
    quit 0
  fi
  if [ ! -e "$expect_path" ]; then
    begin_group 'No expect'
    title="No preexisting $expect_file file"
    instructions=$(
      expect_path=/tmp/expect.txt
      echo 'cat > '"$expect_path"' <<EOF=EOF'
      cat "$run_output"
      echo EOF=EOF
      to_publish_expect "$expect_path" "new"
    )
        spelling_info "$title" "$(bullet_words "$(cat "$run_output")")" "$instructions"
    end_group
    quit 2
  fi
}

grep_v_spellchecker() {
  grep_v_string "$spellchecker"
}

grep_v_string() {
  perl -ne "next if m{$1}; print"
}

compare_new_output() {
  begin_group 'Compare expect with new output'
    sorted_expect="$temp/expect.sorted.txt"
    (sed -e 's/#.*//' "$expect_path" | sort_unique) > "$sorted_expect"
    expect_path="$sorted_expect"

    diff_output=$(
      diff -w -U0 "$expect_path" "$run_output" |
      grep_v_spellchecker)
  end_group

  if [ -z "$diff_output" ]; then
    begin_group 'No misspellings'
    title="No new words with misspellings found"
      spelling_info "$title" "There are currently $(wc -l $expect_path|sed -e 's/ .*//') expected items." ""
    end_group
    quit 0
  fi

  begin_group 'New output'
    new_output=$(
      diff -i -w -U0 "$expect_path" "$run_output" |
      grep_v_spellchecker |\
      perl -n -w -e 'next unless /^\+/; next if /^\+{3} /; s/^.//; print;')
  end_group
}

make_instructions() {
  . "$spellchecker/update-state.sh"
  instructions=$(generate_instructions)
  if [ -n "$patch_add" ]; then
    to_publish_expect "$new_expect_file" $new_expect_file_new >> $instructions
  fi
  cat $instructions
  rm $instructions
}

fewer_misspellings() {
  if [ -z "$new_output" ]; then
    begin_group 'Fewer misspellings'
    title='There are now fewer misspellings than before'
    instructions=$(
    make_instructions
    )
      spelling_info "$title" "$(bullet_words "$patch_add")" "$instructions"
    end_group
    quit
  fi
}
more_misspellings() {
  begin_group 'Misspellings'
  title='Misspellings found, please review'
  instructions=$(
    make_instructions
  )
    spelling_warning "$title" "$(bullet_words "$new_output")" "$instructions"
  end_group
  quit 1
}

main
define_variables
set_up_tools
set_up_files
welcome
run_spell_check
report_first_run
compare_new_output
fewer_misspellings
more_misspellings
