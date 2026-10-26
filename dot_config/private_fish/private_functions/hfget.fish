function hfget --description 'Download Hugging Face files via hf-mirror.com'
    if test (count $argv) -lt 1; or test (count $argv) -gt 2
        echo "用法: hfget <下载链接> [保存目录]"
        echo "示例: hfget 'https://huggingface.co/user/repo/blob/main/model.safetensors' ~/ComfyUI/models/loras"
        return 1
    end

    set -l url "$argv[1]"
    set -l dest "."

    if test (count $argv) -eq 2
        set dest "$argv[2]"
    end

    # 转换为 hf-mirror.com 下载链接
    set url (string replace -r '^https?://huggingface\.co/' 'https://hf-mirror.com/' -- "$url")
    set url (string replace '/blob/' '/resolve/' -- "$url")

    # 创建目标目录（如不存在）
    if not test -d "$dest"
        mkdir -p "$dest"; or return 1
    end

    echo "下载目录: "(realpath "$dest")
    echo "下载地址: $url"

    /usr/local/bin/hfget-wget -c -P "$dest" "$url"
end

