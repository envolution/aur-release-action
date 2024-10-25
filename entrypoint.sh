#!/bin/bash

set -o errexit -o pipefail -o nounset

source /utils.sh

export HOME=/home/builder

debug_git_state() {
    local context="$1"
    echo "=== Git Debug Info: ${context} ==="
    echo "Current directory: $(pwd)"
    echo "Git branch: $(git branch --show-current)"
    echo "Git status:"
    git status
    echo "Git remotes:"
    git remote -v
    echo "=========================="
}

setup_ssh() {
    echo "::group::SSH Setup"
    echo "Getting AUR SSH Public keys"
    ssh-keyscan aur.archlinux.org >>$HOME/.ssh/known_hosts

    echo "Writing SSH Private keys to file"
    echo -e "${INPUT_SSH_PRIVATE_KEY//_/\\n}" >$HOME/.ssh/aur
    chmod 600 $HOME/.ssh/aur*
    echo "::endgroup::"
}

setup_git() {
    echo "::group::Git Setup"
    echo "Setting up Git configuration"
    sudo git config --global user.name "$INPUT_GIT_USERNAME"
    sudo git config --global user.email "$INPUT_GIT_EMAIL"

    # Add github token to the git credential helper
    sudo git config --global core.askPass /cred-helper.sh
    sudo git config --global credential.helper cache

    # Add the working directory as a safe directory
    sudo git config --global --add safe.directory /github/workspace
    echo "::endgroup::"
}

prepare_package() {
    echo "::group::Package Preparation"
    local REPO_URL="ssh://aur@aur.archlinux.org/${INPUT_PACKAGE_NAME}.git"
    
    # Make and enter working directory
    mkdir -p /tmp/package
    pushd /tmp/package || exit 1
    echo "Working in directory: $(pwd)"

    # Copy and update PKGBUILD
    cp "$GITHUB_WORKSPACE/$INPUT_PKGBUILD_PATH" ./PKGBUILD
    
    echo "Updating package checksums"
    updpkgsums
    echo "New checksums: $(grep sha256sums PKGBUILD)"
    
    echo "Current PKGBUILD contents:"
    cat PKGBUILD
    echo "::endgroup::"
}

build_package() {
    if [[ "${INPUT_TRY_BUILD_AND_INSTALL}" == "true" ]]; then
        echo "::group::Package Build"
        echo "Building package"
        makepkg --syncdeps --noconfirm --cleanbuild --rmdeps --install
        echo "::endgroup::"
    fi
}

generate_srcinfo() {
    echo "::group::SRCINFO Generation"
    echo "Generating .SRCINFO"
    makepkg --printsrcinfo >.SRCINFO
    echo "New .SRCINFO contents:"
    cat .SRCINFO
    
    NEW_RELEASE=$(grep pkgver= PKGBUILD | cut -f 2 -d=)
    echo "Detected version: $NEW_RELEASE"
    echo "::endgroup::"
    
    echo "$NEW_RELEASE"
}

update_aur_repo() {
    local new_version="$1"
    local repo_url="ssh://aur@aur.archlinux.org/${INPUT_PACKAGE_NAME}.git"
    
    echo "::group::AUR Update"
    echo "Cloning AUR repository: ${repo_url}"
    git clone "$repo_url"
    
    echo "Copying new files to AUR repo"
    cp -f PKGBUILD .SRCINFO "${INPUT_PACKAGE_NAME}/"
    
    pushd "${INPUT_PACKAGE_NAME}" || exit 1
    debug_git_state "Before AUR commit"
    
    echo "Committing changes to AUR"
    git add PKGBUILD .SRCINFO
    commit "$(generate_commit_message "" "$new_version")"
    git push
    
    debug_git_state "After AUR commit"
    popd || exit 1
    echo "::endgroup::"
}

update_main_repo() {
    local new_version="$1"
    
    echo "::group::Main Repo Update"
    pushd "$GITHUB_WORKSPACE" || exit 1
    debug_git_state "Before main repo update"
    
    # Create update branch
    local update_branch="update_${INPUT_PACKAGE_NAME}_to_${new_version}"
    git checkout -b "$update_branch"
    
    # Update PKGBUILD in main repo
    if [[ "$INPUT_UPDATE_PKGBUILD" == "true" ]]; then
        echo "Updating PKGBUILD in main repo"
        cp /tmp/package/PKGBUILD "$INPUT_PKGBUILD_PATH"
        git add "$INPUT_PKGBUILD_PATH"
        commit "$(generate_commit_message 'PKGBUILD' "$new_version")"
    fi
    
    # Update submodule if specified
    if [[ -n "${INPUT_AUR_SUBMODULE_PATH:-}" ]]; then
        echo "Updating submodule"
        git submodule update --init "$INPUT_AUR_SUBMODULE_PATH"
        git add "$INPUT_AUR_SUBMODULE_PATH"
        commit "$(generate_commit_message 'submodule' "$new_version")"
    fi
    
    # Merge changes back to master
    debug_git_state "Before merge to master"
    git checkout master
    git fetch origin
    git merge "$update_branch" --no-ff
    git push origin master
    
    debug_git_state "After merge to master"
    popd || exit 1
    echo "::endgroup::"
}

main() {
    # Run pre-script if specified
    if [[ -n "${INPUT_PRESCRIPT:-}" ]]; then
        echo "::group::Pre-script"
        echo "Running pre-script"
        eval "${INPUT_PRESCRIPT}"
        echo "::endgroup::"
    fi
    
    setup_ssh
    setup_git
    prepare_package
    build_package
    local new_version
    new_version=$(generate_srcinfo)
    update_aur_repo "$new_version"
    
    if [[ "$INPUT_UPDATE_PKGBUILD" == "true" || -n "${INPUT_AUR_SUBMODULE_PATH:-}" ]]; then
        update_main_repo "$new_version"
    fi
    
    # Run post-script if specified
    if [[ -n "${INPUT_POSTSCRIPT:-}" ]]; then
        echo "::group::Post-script"
        pushd "$GITHUB_WORKSPACE" || exit 1
        echo "Running post-script"
        eval "${INPUT_POSTSCRIPT}"
        popd || exit 1
        echo "::endgroup::"
    fi
}

main "$@"
