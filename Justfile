export repo_organization := env("GITHUB_REPOSITORY_OWNER", "centos-workstation")
export image_name := env("IMAGE_NAME", "main")
export centos_version := env("CENTOS_VERSION", "stream10")
export default_tag := env("DEFAULT_TAG", "latest")
export rechunker_image := "ghcr.io/hhd-dev/rechunk:v1.0.1"

[private]
default:
    @just --list

# Check Just Syntax
[group('Just')]
check:
    #!/usr/bin/bash
    find . -type f -name "*.just" | while read -r file; do
    	echo "Checking syntax: $file"
    	just --unstable --fmt --check -f $file
    done
    echo "Checking syntax: Justfile"
    just --unstable --fmt --check -f Justfile

# Fix Just Syntax
[group('Just')]
fix:
    #!/usr/bin/bash
    find . -type f -name "*.just" | while read -r file; do
    	echo "Checking syntax: $file"
    	just --unstable --fmt -f $file
    done
    echo "Checking syntax: Justfile"
    just --unstable --fmt -f Justfile || { exit 1; }

# Clean Repo
[group('Utility')]
clean:
    #!/usr/bin/bash
    set -eoux pipefail
    touch _build
    find *_build* -exec rm -rf {} \;
    rm -f previous.manifest.json
    rm -f changelog.md
    rm -f output.env

# Sudo Clean Repo
[group('Utility')]
[private]
sudo-clean:
    just sudoif just clean

# sudoif bash function
[group('Utility')]
[private]
sudoif command *args:
    #!/usr/bin/bash
    function sudoif(){
        if [[ "${UID}" -eq 0 ]]; then
            "$@"
        elif [[ "$(command -v sudo)" && -n "${SSH_ASKPASS:-}" ]] && [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]; then
            /usr/bin/sudo --askpass "$@" || exit 1
        elif [[ "$(command -v sudo)" ]]; then
            /usr/bin/sudo "$@" || exit 1
        else
            exit 1
        fi
    }
    sudoif {{ command }} {{ args }}

build $target_image=image_name $tag=default_tag:
    #!/usr/bin/env bash

    # Get Version
    ver="${tag}-${centos_version}.$(date +%Y%m%d)"

    BUILD_ARGS=()
    BUILD_ARGS+=("--build-arg" "MAJOR_VERSION=${centos_version}")
    # BUILD_ARGS+=("--build-arg" "IMAGE_NAME=${image_name}")
    # BUILD_ARGS+=("--build-arg" "IMAGE_VENDOR=${repo_organization}")
    # if [[ -z "$(git status -s)" ]]; then
    #     BUILD_ARGS+=("--build-arg" "SHA_HEAD_SHORT=$(git rev-parse --short HEAD)")
    # fi

    LABELS=()
    LABELS+=("--label" "org.opencontainers.image.title=${image_name}")
    LABELS+=("--label" "org.opencontainers.image.version=${ver}")
    # LABELS+=("--label" "ostree.linux=${kernel_release}")
    LABELS+=("--label" "io.artifacthub.package.readme-url=https://raw.githubusercontent.com/ublue-os/bluefin/bluefin/README.md")
    LABELS+=("--label" "io.artifacthub.package.logo-url=https://avatars.githubusercontent.com/u/120078124?s=200&v=4")
    LABELS+=("--label" "org.opencontainers.image.description=CentOS based images")

    podman build \
        "${BUILD_ARGS[@]}" \
        "${LABELS[@]}" \
        --tag "${target_image}:${tag}" \
        .

_rootful_load_image $target_image=image_name $tag=default_tag:
    #!/usr/bin/bash
    set -eoux pipefail

    if [[ -n "${SUDO_USER:-}" || "${UID}" -eq "0" ]]; then
        echo "Already root or running under sudo, no need to load image from user podman."
        exit 0
    fi

    set +e
    resolved_tag=$(podman inspect -t image "${target_image}:${tag}" | jq -r '.[].RepoTags.[0]')
    return_code=$?
    set -e

    if [[ $return_code -eq 0 ]]; then
        # Load into Rootful Podman
        ID=$(just sudoif podman images --filter reference="${target_image}:${tag}" --format "'{{ '{{.ID}}' }}'")
        if [[ -z "$ID" ]]; then
            COPYTMP=$(mktemp -p "${PWD}" -d -t _build_podman_scp.XXXXXXXXXX)
            just sudoif TMPDIR=${COPYTMP} podman image scp ${UID}@localhost::"${target_image}:${tag}" root@localhost::"${target_image}:${tag}"
            rm -rf "${COPYTMP}"
        fi
    else
        # Make sure the image is present and/or up to date
        just sudoif podman pull "${target_image}:${tag}"
    fi

_build-bib $target_image $tag $type $config: (_rootful_load_image target_image tag)
    #!/usr/bin/env bash
    set -euo pipefail

    echo "Cleaning up previous build"
    sudo rm -rf "output/${type}" || true
    sudo rm "output/manifest-${type}.json" || true

    args="--type ${type}"

    if [[ $target_image == localhost/* ]]; then
      args+=" --local"
    fi

    sudo podman run \
      --rm \
      -it \
      --privileged \
      --pull=newer \
      --security-opt label=type:unconfined_t \
      -v $(pwd)/${config} \
      -v $(pwd)/output:/output \
      -v /var/lib/containers/storage:/var/lib/containers/storage \
      quay.io/centos-bootc/bootc-image-builder:latest \
      ${args} \
      "${target_image}"

    sudo chown -R $USER:$USER output

    if [[ $type == qcow2 ]]; then
      echo "making the image biggerer"
      sudo qemu-img resize "output/qcow2/disk.qcow2" 80G
    fi

build-vm $target_image=("localhost/" + image_name) $tag=default_tag: && (_build-bib target_image tag "qcow2" "image-builder.config.toml")

build-iso $target_image=("localhost/" + image_name) $tag=default_tag: && (_build-bib target_image tag "iso" "image-builder-iso.config.toml")

run-vm $target_image=("localhost/" + image_name) $tag=default_tag:
    #!/usr/bin/bash
    set -eoux pipefail

    qcow2_file="output/qcow2/disk.qcow2"

    if [[ ! -f "${qcow2_file}" ]]; then
        just build-vm "$target_image" "$tag"
    fi

    # Determine which port to use
    port=8006;
    while grep -q :${port} <<< $(ss -tunalp); do
        port=$(( port + 1 ))
    done
    echo "Using Port: ${port}"
    echo "Connect to http://localhost:${port}"
    run_args=()
    run_args+=(--rm --privileged)
    run_args+=(--pull=newer)
    run_args+=(--publish "127.0.0.1:${port}:8006")
    run_args+=(--env "CPU_CORES=4")
    run_args+=(--env "RAM_SIZE=8G")
    run_args+=(--env "DISK_SIZE=64G")
    # run_args+=(--env "BOOT_MODE=windows_secure")
    run_args+=(--env "TPM=Y")
    run_args+=(--env "GPU=Y")
    run_args+=(--device=/dev/kvm)
    run_args+=(--volume "${PWD}/${qcow2_file}":"/boot.qcow2")
    run_args+=(docker.io/qemux/qemu-docker)
    podman run "${run_args[@]}" &
    xdg-open http://localhost:${port}
    fg "%podman"

run-iso $target_image=("localhost/" + image_name) $tag=default_tag:
    #!/usr/bin/bash
    set -eoux pipefail

    iso_file="output/iso/myiso.iso"

    if [[ ! -f "${iso_file}" ]]; then
        just build-iso "$target_image" "$tag"
    fi

    # Determine which port to use
    port=8006;
    while grep -q :${port} <<< $(ss -tunalp); do
        port=$(( port + 1 ))
    done
    echo "Using Port: ${port}"
    echo "Connect to http://localhost:${port}"
    run_args=()
    run_args+=(--rm --privileged)
    run_args+=(--pull=newer)
    run_args+=(--publish "127.0.0.1:${port}:8006")
    run_args+=(--env "CPU_CORES=4")
    run_args+=(--env "RAM_SIZE=8G")
    run_args+=(--env "DISK_SIZE=64G")
    # run_args+=(--env "BOOT_MODE=windows_secure")
    run_args+=(--env "TPM=Y")
    run_args+=(--env "GPU=Y")
    run_args+=(--device=/dev/kvm)
    run_args+=(--volume "${PWD}/${iso_file}":"/boot.iso")
    run_args+=(docker.io/qemux/qemu-docker)
    podman run "${run_args[@]}" &
    xdg-open http://localhost:${port}
    fg "%podman"

export rechunk_dir := "_build_rechunk"

rechunk $target_image=("localhost/" + image_name) $centos_version="stream10" $tag="latest": (_rootful_load_image target_image tag)
    #!/usr/bin/bash
    set -eoux pipefail

    # Prep Container
    CREF=$(just sudoif podman create "${target_image}":"${tag}" bash)
    OLD_IMAGE=$(just sudoif podman inspect $CREF | jq -r '.[].Image')
    OUT_NAME="${image_name}_build"
    MOUNT=$(just sudoif podman mount "${CREF}")

    # Label Version
    if [[ "{{ tag }}" =~ stable ]]; then
        VERSION="${centos_version}.$(date +%Y%m%d)"
    else
        VERSION="${tag}-${centos_version}.$(date +%Y%m%d)"
    fi

    # TODO: port over cleanup code to facilitate running in GitHub actions

    # Run Rechunker's Prune
    just sudoif podman run --rm \
        --pull=newer \
        --security-opt label=disable \
        --volume "$MOUNT":/var/tree \
        --env TREE=/var/tree \
        --user 0:0 \
        "${rechunker_image}" \
        /sources/rechunk/1_prune.sh

    # Run Rechunker's Create
    just sudoif podman run --rm \
        --pull=newer \
        --security-opt label=disable \
        --volume "$MOUNT":/var/tree \
        --env TREE=/var/tree \
        --user 0:0 \
        "${rechunker_image}" \
        /sources/rechunk/1_prune.sh

    # Cleanup Temp Container Reference
    just sudoif podman unmount "$CREF"
    just sudoif podman rm "$CREF"
    just sudoif podman rmi "$OLD_IMAGE"

    mkdir -p "${rechunk_dir}"

    SHA="dedbeef"
    if [[ -z "$(git status -s)" ]]; then
        SHA=$(git rev-parse HEAD)
    fi

    PREV_REF="ghcr.io/${repo_organization}/${image_name}:${tag}"
    just sudoif podman run --rm \
        --pull=newer \
        --security-opt label=disable \
        --volume "${PWD}/${rechunk_dir}:/workspace" \
        --volume "${PWD}:/var/git" \
        --volume cache_ostree:/var/ostree \
        --env REPO=/var/ostree/repo \
        --env PREV_REF="${PREV_REF}" \
        --env OUT_NAME="${OUT_NAME}" \
        --env LABELS="org.opencontainers.image.title=${image_name}$'\n'" \
        --env "DESCRIPTION='CentOS based images'" \
        --env "VERSION=${VERSION}" \
        --env VERSION_FN=/workspace/version.txt \
        --env OUT_REF="oci:$OUT_NAME" \
        --env GIT_DIR="/var/git" \
        --env REVISION="$SHA" \
        --user 0:0 \
        "${rechunker_image}" \
        /sources/rechunk/3_chunk.sh

    # Fix Permissions of OCI
    if [[ "${UID}" -gt "0" ]]; then
        just sudoif chown "${UID}:${GROUPS}" -R "${rechunk_dir}"
    elif [[ -n "${SUDO_UID:-}" ]]; then
        chown "${SUDO_UID}":"${SUDO_GID}" -R "${rechunk_dir}"
    fi

    # Remove cache_ostree
    just sudoif podman volume rm cache_ostree

    # Show OCI Labels
    just sudoif skopeo inspect oci:"${rechunk_dir}"/"${OUT_NAME}" | jq -r '.Labels'

    rm -rf "${rechunk_dir}"

load-rechunk $tag="latest":
    #!/usr/bin/bash
    set -eou pipefail

    # Load Image
    OUT_NAME="${image_name}_build"
    IMAGE=$(podman pull "oci:${rechunk_dir}/${OUT_NAME}")
    podman tag ${IMAGE} "localhost/${image_name}:${tag}"

    # Cleanup
    just sudoif "rm -rf ${OUT_NAME}*"
    just sudoif "rm -f previous.manifest.json"
