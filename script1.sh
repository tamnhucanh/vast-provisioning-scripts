#!/bin/bash

set -e
set -o pipefail

echo "Starting provisioning script for Forge UI customization..."

# Ensure required tools are installed
for cmd in curl jq git; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "ERROR: $cmd is not installed. Please install it and try again."
        exit 1
    fi
done

# Environment variables
CIVITAI_TOKEN="${CIVITAI_TOKEN:-}"
MODEL_DIR="/workspace/stable-diffusion-webui-forge/models/Stable-diffusion"
LORA_DIR="/workspace/stable-diffusion-webui-forge/models/Lora"
MAX_RETRIES=3
RETRY_DELAY=10
CURL_TIMEOUT=300

# Disk space check (30GB in KB)
MIN_DISK_SPACE=$((30 * 1024 * 1024))
AVAILABLE_SPACE=$(df --output=avail /workspace | tail -n 1)
if [ "$AVAILABLE_SPACE" -lt "$MIN_DISK_SPACE" ]; then
    echo "ERROR: Insufficient disk space. Available: $AVAILABLE_SPACE KB, Required: $MIN_DISK_SPACE KB"
    echo "Note: Provisioning encountered issues but instance startup will continue"
    exit 1
fi
echo "Disk space check passed. Available: $AVAILABLE_SPACE KB"

# Validate CivitAI API token
echo "Validating CivitAI API token..."
if [ -z "$CIVITAI_TOKEN" ]; then
    echo "ERROR: CIVITAI_TOKEN environment variable is not set."
    exit 1
fi

validate_token() {
    local response
    response=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $CIVITAI_TOKEN" "https://civitai.com/api/v1/models?limit=1")
    if [ "$response" -eq 200 ]; then
        echo "CivitAI API token validated successfully."
    else
        echo "ERROR: Invalid CivitAI API token or API error (HTTP $response)."
        exit 1
    fi
}
validate_token

# Create directories if they don't exist
mkdir -p "$MODEL_DIR" "$LORA_DIR"
mkdir -p "/workspace/stable-diffusion-webui-forge/models/ControlNet"
mkdir -p "/workspace/stable-diffusion-webui-forge/models/VAE"

# Install extensions
install_extension() {
    local repo_url="$1"
    local dir_name="$2"
    local target_dir="/workspace/stable-diffusion-webui-forge/extensions/$dir_name"
    echo "Installing extension: $dir_name"
    if [ -d "$target_dir" ]; then
        echo "Extension $dir_name already exists, skipping clone."
    else
        git clone "$repo_url" "$target_dir" || {
            echo "ERROR: Failed to clone $repo_url"
            exit 1
        }
    fi
}

install_extension "https://github.com/Mikubill/sd-webui-controlnet.git" "sd-webui-controlnet"
install_extension "https://github.com/kohya-ss/sd-webui-additional-networks.git" "sd-webui-additional-networks"
install_extension "https://github.com/AUTOMATIC1111/stable-diffusion-webui-images-browser.git" "stable-diffusion-webui-images-browser"
install_extension "https://github.com/DominikDoom/a1111-sd-webui-tagcomplete.git" "a1111-sd-webui-tagcomplete"
install_extension "https://github.com/adieyal/sd-dynamic-prompts.git" "sd-dynamic-prompts"
install_extension "https://github.com/civitai/sd_civitai_extension.git" "sd-civitai-browser-plus"
install_extension "https://github.com/Bing-su/adetailer.git" "adetailer"

# Download ControlNet models and VAE
download_controlnet() {
    local url="$1"
    local filename="$2"
    local target="/workspace/stable-diffusion-webui-forge/models/ControlNet/$filename"
    if [ -f "$target" ]; then
        echo "ControlNet model $filename already exists, skipping download."
    else
        echo "Downloading ControlNet model: $filename"
        wget -q --show-progress "$url" -O "$target" || {
            echo "ERROR: Failed to download $filename"
            exit 1
        }
    fi
}

download_controlnet "https://huggingface.co/lllyasviel/ControlNet-v1-1/resolve/main/control_v11p_sd15_canny.pth" "control_v11p_sd15_canny.pth"
download_controlnet "https://huggingface.co/lllyasviel/ControlNet-v1-1/resolve/main/control_v11p_sd15_openpose.pth" "control_v11p_sd15_openpose.pth"
download_controlnet "https://huggingface.co/lllyasviel/ControlNet-v1-1/resolve/main/control_v11f1p_sd15_depth.pth" "control_v11f1p_sd15_depth.pth"

# Download VAE
if [ -f "/workspace/stable-diffusion-webui-forge/models/VAE/vae-ft-mse-840000-ema-pruned.safetensors" ]; then
    echo "VAE vae-ft-mse-840000-ema-pruned.safetensors already exists, skipping download."
else
    echo "Downloading VAE: vae-ft-mse-840000-ema-pruned.safetensors"
    wget -q --show-progress "https://huggingface.co/stabilityai/sd-vae-ft-mse-original/resolve/main/vae-ft-mse-840000-ema-pruned.safetensors" \
        -O "/workspace/stable-diffusion-webui-forge/models/VAE/vae-ft-mse-840000-ema-pruned.safetensors" || {
        echo "ERROR: Failed to download VAE"
        exit 1
    }
fi

# Download models and LoRAs from CivitAI
sanitize() {
    local input="$1"
    echo "$input" | tr -dc '[:alnum:]_-' | tr '[:upper:]' '[:lower:]'
}

validate_model_id() {
    local model_version_id="$1"
    local response api_status
    response=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer $CIVITAI_TOKEN" "https://civitai.com/api/v1/model-versions/$model_version_id")
    api_status=$(echo "$response" | tail -n 1)
    if [ "$api_status" -eq 200 ]; then
        echo "Model ID $model_version_id is valid"
        echo "$response" | head -n -1
    elif [[ $api_status == "429" ]]; then
        echo "ERROR: Rate limit hit for model $model_version_id. Waiting 60 seconds..."
        sleep 60
        return 1
    else
        echo "ERROR: Invalid model ID $model_version_id or API error (HTTP $api_status)."
        return 1
    fi
}

download_civit_model() {
    local model_version_id="$1"
    local target_dir="$2"
    local attempt=1
    local max_attempts=$MAX_RETRIES
    local model_info_response model_info model_name model_version model_type filename_base model_file preview_image model_url preview_url
    local model_file_downloaded=false preview_downloaded=false

    echo "Processing model $model_version_id to $target_dir"

    while [ $attempt -le $max_attempts ]; do
        echo "Attempt $attempt/$max_attempts: Fetching metadata for model version $model_version_id..."
        model_info_response=$(validate_model_id "$model_version_id")
        if [ $? -eq 0 ]; then
            model_info=$(echo "$model_info_response")
            model_name=$(echo "$model_info" | jq -r '.name' | tr ' ' '_')
            model_version=$(echo "$model_info" | jq -r '.version' | tr ' ' '_')
            model_type=$(echo "$model_info" | jq -r '.model.type')
            filename_base=$(sanitize "${model_name}_${model_version}")
            echo "Model info: '$model_name' version '$model_version' (type: $model_type)"
            echo "Using filename base: $filename_base"

            # Determine file extension
            model_url=$(echo "$model_info" | jq -r '.files[] | select(.type == "Model") | .downloadUrl')
            if [[ $model_url == *.safetensors ]]; then
                model_file="$filename_base.safetensors"
            elif [[ $model_url == *.ckpt ]]; then
                model_file="$filename_base.ckpt"
            else
                echo "ERROR: Unsupported model file format for $model_version_id."
                DOWNLOAD_STATUS[$model_version_id]="Failed (unsupported format)"
                return 1
            fi

            # Download model file
            if [ -f "$target_dir/$model_file" ]; then
                echo "Model file $model_file already exists, skipping download."
                model_file_downloaded=true
            else
                echo "Downloading model: $model_file"
                if curl -s -H "Authorization: Bearer $CIVITAI_TOKEN" --max-time "$CURL_TIMEOUT" -o "$target_dir/$model_file" "$model_url"; then
                    model_file_downloaded=true
                else
                    echo "ERROR: Failed to download model file $model_file (attempt $attempt/$max_attempts)."
                    rm -f "$target_dir/$model_file"
                fi
            fi

            # Download preview image
            preview_url=$(echo "$model_info" | jq -r '.images[] | select(.type == "image") | .url' | head -n 1)
            if [ -n "$preview_url" ]; then
                if [ -f "$target_dir/$filename_base.preview.png" ]; then
                    echo "Preview image $filename_base.preview.png already exists, skipping download."
                    preview_downloaded=true
                else
                    echo "Downloading preview image: $filename_base.preview.png"
                    if curl -s --max-time "$CURL_TIMEOUT" -o "$target_dir/$filename_base.preview.png" "$preview_url"; then
                        preview_downloaded=true
                    else
                        echo "ERROR: Failed to download preview image $filename_base.preview.png (attempt $attempt/$max_attempts)."
                        rm -f "$target_dir/$filename_base.preview.png"
                    fi
                fi
            else
                echo "No preview image available for $model_version_id."
                preview_downloaded=true
            fi

            # Download model info as JSON
            if [ -f "$target_dir/$filename_base.json" ]; then
                echo "Model info JSON $filename_base.json already exists, skipping download."
            else
                echo "Saving model info as: $filename_base.json"
                echo "$model_info" | jq '.' > "$target_dir/$filename_base.json" || {
                    echo "ERROR: Failed to save model info JSON for $model_version_id."
                }
            fi

            # Check if all downloads were successful
            if $model_file_downloaded && $preview_downloaded; then
                echo "Successfully processed model $model_version_id: $model_name ($model_version)"
                DOWNLOAD_STATUS[$model_version_id]="Success"
                return 0
            fi
        else
            echo "ERROR: Failed to validate model $model_version_id (attempt $attempt/$max_attempts)."
        fi

        attempt=$((attempt + 1))
        if [ $attempt -le $max_attempts ]; then
            echo "Retrying after $RETRY_DELAY seconds..."
            sleep "$RETRY_DELAY"
        fi
    done

    echo "ERROR: Failed to download model $model_version_id after $max_attempts attempts."
    DOWNLOAD_STATUS[$model_version_id]="Failed (max retries reached)"
    return 1
}

download_model_wrapper() {
    local id="$1"
    local model_version_id="${id:1}"
    local target_dir

    echo "Starting download wrapper for $id"

    if [[ $id == m* ]]; then
        target_dir="$MODEL_DIR"
    elif [[ $id == l* ]]; then
        target_dir="$LORA_DIR"
    else
        echo "ERROR: Invalid ID format for $id. Must start with 'm' (model) or 'l' (LoRA)."
        DOWNLOAD_STATUS[$model_version_id]="Failed (invalid ID)"
        return 1
    fi

    download_civit_model "$model_version_id" "$target_dir"
    local status=$?
    echo "Completed download of $id"
    return $status
}

# Declare DOWNLOAD_STATUS as an associative array
declare -A DOWNLOAD_STATUS

# Download models and LoRAs in parallel
download_batch() {
    local ids=("$@")
    echo "Starting parallel download_batch with ${#ids[@]} models/LoRAs: ${ids[*]}"

    # Export functions and variables for xargs
    export -f download_civit_model download_model_wrapper sanitize validate_model_id
    export CIVITAI_TOKEN MODEL_DIR LORA_DIR MAX_RETRIES RETRY_DELAY CURL_TIMEOUT

    # Run downloads in parallel with xargs, max 3 at a time
    printf "%s\n" "${ids[@]}" | xargs -n 1 -P 3 -I {} bash -c 'download_model_wrapper "{}"'

    # Print summary of download outcomes
    echo "=== Download Summary ==="
    for id in "${ids[@]}"; do
        model_id="${id:1}"
        status="${DOWNLOAD_STATUS[$model_id]:-Not attempted}"
        echo "$id: $status"
    done
}

# List of models and LoRAs to download
download_batch \
    "m1166878" \
    "m1612720" \
    "m1111838" \
    "l1568786" \
    "l1074877" \
    "l1486082" \
    "l1360425" \
    "l1470544" \
    "l1645427" \
    "l999582" \
    "l1364444" \
    "l1458421"

echo "Provisioning completed successfully! Check $MODEL_DIR and $LORA_DIR"
exit 0
