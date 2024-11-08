#!/bin/bash

set -eux -o pipefail

version=$1 # e.g. 2024-07
is_early_access=$2 # e.g. true

# if is_early_access is true, add the "ea" module
if [ "$is_early_access" = "true" ]; then
	destination="pinecone/core_ea/openapi"
	modules=("db_control" "db_data")
	py_module_name="core_ea"
	template_dir="codegen/python-oas-templates/templates5.2.0"
else
	destination="pinecone/core/openapi"
	modules=("control" "data")
	py_module_name="core"
	template_dir="codegen/python-oas-templates/templates5.2.0"
fi

build_dir="build"

update_apis_repo() {
	echo "Updating apis repo"
	pushd codegen/apis
		git fetch
		git checkout main
		git pull
		just build
	popd
}

update_templates_repo() {
	echo "Updating templates repo"
	pushd codegen/python-oas-templates
		git fetch
		git checkout main
		git pull
	popd
}

verify_spec_version() {
	local version=$1
	echo "Verifying spec version $version exists in apis repo"
	if [ -z "$version" ]; then
		echo "Version is required"
		exit 1
	fi

	verify_directory_exists "codegen/apis/_build/${version}"
}

verify_file_exists() {
	local filename=$1
	if [ ! -f "$filename" ]; then
		echo "File does not exist at $filename"
		exit 1
	fi
}

verify_directory_exists() {
	local directory=$1
	if [ ! -d "$directory" ]; then
		echo "Directory does not exist at $directory"
		exit 1
	fi
}

generate_client() {
	local module_name=$1

	oas_file="codegen/apis/_build/${version}/${module_name}_${version}.oas.yaml"
	package_name="pinecone.${py_module_name}.openapi.${module_name}"

	verify_file_exists $oas_file
	verify_directory_exists $template_dir

	# Cleanup previous build files
	echo "Cleaning up previous build files"
	rm -rf "${build_dir}"

	# Generate client module
	docker run --rm -v $(pwd):/workspace openapitools/openapi-generator-cli:v5.2.0 generate \
		--input-spec "/workspace/$oas_file" \
		--generator-name python \
		--additional-properties=packageName=$package_name,pythonAttrNoneIfUnset=true,exceptionsPackageName=pinecone.core.openapi.shared.exceptions \
		--output "/workspace/${build_dir}" \
		--template-dir "/workspace/$template_dir"

	# Hack to prevent coercion of strings into datetimes within "object" types while still
	# allowing datetime parsing for fields that are explicitly typed as datetime
	find "${build_dir}" -name "*.py" | while IFS= read -r file; do
		sed -i '' "s/bool, date, datetime, dict, float, int, list, str, none_type/bool, dict, float, int, list, str, none_type/g" "$file"
	done

	# Copy the generated module to the correct location
	rm -rf "${destination}/${module_name}"
	mkdir -p "${destination}"
	cp -r "build/pinecone/$py_module_name/openapi/${module_name}" "${destination}/${module_name}"
}

extract_shared_classes() {
	target_directory="${destination}/shared"
	mkdir -p "$target_directory"

	# Define the list of shared source files
	sharedFiles=(
		"api_client"
		"configuration"
		"exceptions"
		"model_utils"
		"rest"
	)

	source_directory="${destination}/${modules[0]}"

	# Loop through each file we want to share and copy it to the target directory
	for file in "${sharedFiles[@]}"; do
		cp "${source_directory}/${file}.py" "$target_directory"
	done

	# Cleanup shared files in each module
	for module in "${modules[@]}"; do
		source_directory="${destination}/${module}"
		for file in "${sharedFiles[@]}"; do
			rm "${source_directory}/${file}.py"
		done
	done

	# Remove the docstring headers that aren't really correct in the
	# context of this new shared package structure
	find "$target_directory" -name "*.py" -print0 | xargs -0 -I {} sh -c 'sed -i "" "/^\"\"\"/,/^\"\"\"/d" "{}"'

	echo "All shared files have been copied to $target_directory."

	# Adjust import paths in every file
	find "${destination}" -name "*.py" | while IFS= read -r file; do
		sed -i '' "s/from \.\.model_utils/from pinecone\.$py_module_name\.openapi\.shared\.model_utils/g" "$file"

		for module in "${modules[@]}"; do
			sed -i '' "s/from pinecone\.$py_module_name\.openapi\.$module import rest/from pinecone\.$py_module_name\.openapi\.shared import rest/g" "$file"

			for sharedFile in "${sharedFiles[@]}"; do
				sed -i '' "s/from pinecone\.$py_module_name\.openapi\.$module\.$sharedFile/from pinecone\.$py_module_name\.openapi\.shared\.$sharedFile/g" "$file"
			done
		done
	done

	echo "API_VERSION = '${version}'" > "${target_directory}/__init__.py"
}

update_apis_repo
update_templates_repo
verify_spec_version $version

rm -rf "${destination}"
mkdir -p "${destination}"

for module in "${modules[@]}"; do
	generate_client $module
done

# Even though we want to generate multiple packages, we
# don't want to duplicate every exception and utility class.
# So we do a bit of surgery to combine the shared files.
extract_shared_classes

# Format generated files
poetry run ruff format "${destination}"
