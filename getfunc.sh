#!/bin/sh
# extract_prototype.sh

if [ $# -ne 2 ]; then
    echo "Usage: $0 <file.c> <function_name>"
    exit 1
fi

FUNC_NAME="$2"

result=$(clang -Xclang -ast-dump=json -fsyntax-only "$1" 2>/dev/null | \
    jq -r --arg fname "$FUNC_NAME" '
    .. | 
    select(.kind? == "FunctionDecl" and .name? == $fname and .loc?.file? and .inner?) | 
    (.type.qualType // .type) as $ret |
    .name as $name |
    (
        if .inner then
            [.inner[] | select(.kind == "ParmVarDecl") | (.type.qualType // "void") + " " + (.name // "")] | join(", ")
        else
            ""
        end
    ) as $args |
    "\($ret) \($name)(\($args));"
    ')

if [ -z "$result" ]; then
    echo "Error: Function '$FUNC_NAME' not found in $1" >&2
    exit 1
fi

echo "$result"
