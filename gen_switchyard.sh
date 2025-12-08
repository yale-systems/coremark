#!/bin/sh
# generate_switchyard.sh

if [ $# -ne 2 ]; then
    echo "Usage: $0 <file.c> <function_name>"
    exit 1
fi

src_file="$1"
func_name="$2"

# Extract function info as JSON
func_info=$(clang -Xclang -ast-dump=json -fsyntax-only "$src_file" 2>/dev/null | \
    jq --arg fname "$func_name" '
    .. | 
    select(.kind? == "FunctionDecl" and .name? == $fname and .loc?.file?) | 
    {
        returnType: (.returnType.qualType // .type.qualType // "void"),
        name: .name,
        params: [.inner[]? | select(.kind == "ParmVarDecl") | 
            {
                type: (.type.qualType // .type.desugaredQualType // "void"),
                name: (.name // "")
            }
        ]
    }
    ' | head -1)

if [ -z "$func_info" ]; then
    echo "Error: Function '$func_name' not found in $src_file" >&2
    exit 1
fi

# Parse JSON
ret_type=$(echo "$func_info" | jq -r '.returnType')
params=$(echo "$func_info" | jq -r '.params | map(.type + (if .name != "" then " " + .name else "" end)) | join(", ")')
param_names=$(echo "$func_info" | jq -r '.params | map(.name // "") | join(", ")')

# Fallback if return type is empty
[ -z "$ret_type" ] && ret_type="void"
[ -z "$params" ] && params="void"
[ -z "$param_names" ] && param_names=""

# Generate code
cat << EOF
#include <stdlib.h>
#include <time.h>

$ret_type ${func_name}_generic($params);
$ret_type ${func_name}_fast($params);

$ret_type ${func_name}_switchyard($params) {
    srand(time(NULL));
    if (rand() % 2)
        return ${func_name}_generic($param_names);
    else
        return ${func_name}_fast($param_names);
}
EOF
