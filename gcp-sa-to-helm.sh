#!/bin/bash

# purpose: 
# this script will pull the active service account permissions based on repo name
# the repo name reflects the application name
# clone the repo 
# create a branch
# pulling the service account information and populating it in helm-dev
# push the change
# create a pull request with permission details


# requirements:
# access to google cloud platform - project 
# access to github org/repo
# run on apple mac
# gh api installed https://github.com/cli/cli


# variables
project_id="" # <<<<< populate the google cloud project 

owner="" # <<<<< populate the github owner

branch_name="add-sa-to-helm-dev" # <<<<< populate the github chore branch


# run gcloud command to list service accounts and capture the output
service_accounts=$(gcloud iam service-accounts list --format=json)

# iterate over each service account
for row in $(echo "${service_accounts}" | jq -r '.[] | @base64'); do
    _jq() {
        echo "${row}" | base64 --decode | jq -r "${1}"
    }

    # extract relevant information from each service account
    account_email=$(_jq '.email')
    account_display_name=$(_jq '.displayName')

    # output filename based on service account email
    output_file="${account_email//[@.]/_}.json"

    # run gcloud command to get IAM policy for the project and capture the output
    permissions=$(gcloud projects get-iam-policy "${project_id}" \
                   --flatten="bindings[].members" \
                   --format='csv(bindings.role)' \
                   --filter="bindings.members:${account_email}")

    # check if there are any roles associated with the service account
    if [[ -z "${permissions}" ]]; then
        echo "No roles found for service account: ${account_email}. Skipping..."
        rm $output_file
        continue
    fi

    # write service account information along with permissions to file
    echo "{ \"email\": \"${account_email}\", \"displayName\": \"${account_display_name}\", \"permissions\": ${permissions} }" > "${output_file}"

    echo "Service Account information with permissions written to ${output_file}"

    # extract service account name from email
    sa_name=$(echo "${account_email}" | cut -d'@' -f1)

    # check if the repository exists for the service account
    if ! git ls-remote --exit-code "https://github.com/BenefexLtd/${sa_name}.git" &> /dev/null; then
        echo "No repository found for service account: ${sa_name}. Skipping..."
        echo "Remove JSON file"
        rm $output_file
        continue
    fi

    # get the archived status of the repository
    is_archived=$(gh api "/repos/BenefexLtd/${sa_name}" | jq -r '.archived')

    # check if the repository is archived
    if [[ "$is_archived" == "true" ]]; then
        echo "Repository for service account ${sa_name} is archived. Skipping..."
        echo "Remove JSON file"
        rm $output_file
        continue  # Skip to the next iteration of the loop
    fi

    # clone the repository
    repo_url="https://github.com/${owner}/${sa_name}.git"
    git clone "${repo_url}"
    
    # create a branch called "add-sa-to-helm" and switch to it
    cd "${sa_name}"
    git checkout -b $branch_name

    # update helm-dev.yml file with roles
    helm_values_file="helm-dev.yml"
    # build roles list from permissions
    roles=$(echo "${permissions}" | sed 's/, /\\n/g' | sed 's/^-\ roles\///' | sed 's/^roles\///' | sed '/^\s*$/d' | sed '1s/^role$//' | sed '/^\s*$/d' | sed 's/^/    - /')
    echo "$roles"

    # append roles to the helm-dev.yml file
    echo "" >> "${helm_values_file}"
    echo "project: $project_id" >> "${helm_values_file}"
    echo "" >> "${helm_values_file}"
    echo "createserviceAccount:" >> "${helm_values_file}"
    echo "  enabled: true" >> "${helm_values_file}"
    echo "  roles:" >> "${helm_values_file}"
    echo "${roles}" >> "${helm_values_file}"

    # commit and push changes
    echo "performing commit and push"
    git add "${helm_values_file}"
    git commit -m "Add roles to helm-dev.yml"
    git push --set-upstream origin $branch_name

    # create a pull request
    pr_title="Add roles to helm-dev.yml for ${sa_name}"
    pr_description="

## :spiral_notepad: What's being changed?
adding the below roles to helm-dev:
${roles}


## :interrobang: Why is it being changed?


## :bomb: Potential Impact
low

## Rollback: 

## :test_tube: How to test/verify the change?


    "
    gh pr create --title "${pr_title}" --body "${pr_description}"
    echo "pull request created"

    cd ..
    echo "Remove JSON file"
    rm $output_file
done
