#!/usr/bin/env python3
"""gen_tokenizer.py — 为测试夹具模型生成 byte-level BPE tokenizer.json（8192 vocab）

夹具模型（make_glm_bench_model.py）只产权重和 config，不产 tokenizer。
本脚本合成一个结构合法的 tokenizer.json：
  - ids 0-255:    GPT-2/cl100k 标准 byte-level 字节字符（与上游 tok.h 的 bytemap 一致）
  - ids 256-8188: 占位 dummy token（随机权重夹具的输出会落在这里，可解码为字面串）
  - ids 8189-8191: added_tokens <|observation|> <|user|> <|endoftext|>
                   （上游引擎用 tok_id_of(T,"<|endoftext|>") 取停止符，config 的
                   eos_token_id 也指向这三个 — 与真实 GLM-5.2 的三停止符结构一致）

用法: gen_tokenizer.py <模型目录>
"""
import json
import sys


def bytes_to_unicode():
    """GPT-2 经典字节→unicode 映射（可见字节映自身，其余映到 256+n）。"""
    bs = (list(range(ord("!"), ord("~") + 1))
          + list(range(ord("¡"), ord("¬") + 1))
          + list(range(ord("®"), ord("ÿ") + 1)))
    cs = bs[:]
    n = 0
    for b in range(256):
        if b not in bs:
            bs.append(b)
            cs.append(256 + n)
            n += 1
    return dict(zip(bs, [chr(c) for c in cs]))


def main(model_dir: str) -> None:
    b2u = bytes_to_unicode()
    vocab = {b2u[b]: b for b in range(256)}
    for i in range(256, 8189):
        vocab[f"<tok_{i}>"] = i
    added = [
        {"id": 8189, "content": "<|observation|>", "special": True,
         "single_word": False, "lstrip": False, "rstrip": False, "normalized": False},
        {"id": 8190, "content": "<|user|>", "special": True,
         "single_word": False, "lstrip": False, "rstrip": False, "normalized": False},
        {"id": 8191, "content": "<|endoftext|>", "special": True,
         "single_word": False, "lstrip": False, "rstrip": False, "normalized": False},
    ]
    tok = {
        "version": "1.0",
        "truncation": None,
        "padding": None,
        "added_tokens": added,
        "normalizer": None,
        "pre_tokenizer": {
            "type": "Sequence",
            "pretokenizers": [
                {"type": "Split",
                 "pattern": {"Regex": "(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\\r\\n\\p{L}\\p{N}]?\\p{L}+|\\p{N}{1,3}| ?[^\\s\\p{L}\\p{N}]+[\\r\\n]*|\\s*[\\r\\n]+|\\s+(?!\\S)|\\s+"},
                 "behavior": "Isolated", "invert": False},
                {"type": "ByteLevel", "add_prefix_space": False,
                 "trim_offsets": True, "use_regex": False},
            ],
        },
        "post_processor": None,
        "decoder": {"type": "ByteLevel", "add_prefix_space": False,
                    "trim_offsets": True, "use_regex": False},
        "model": {"type": "BPE", "dropout": None, "unk_token": None,
                  "continuing_subword_prefix": None, "end_of_word_suffix": None,
                  "fuse_unk": False, "byte_fallback": False, "ignore_merges": True,
                  "vocab": vocab, "merges": []},
    }
    with open(f"{model_dir}/tokenizer.json", "w", encoding="utf-8") as f:
        json.dump(tok, f, ensure_ascii=False)

    cfg_path = f"{model_dir}/config.json"
    cfg = json.load(open(cfg_path))
    cfg["eos_token_id"] = [8191, 8190, 8189]  # endoftext / user / observation
    with open(cfg_path, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2)
    print(f"tokenizer.json + eos_token_id written: {model_dir}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    main(sys.argv[1])
