# Hướng dẫn cài đặt Rust + Arkworks và chạy thực nghiệm 20M Circuit

## Mục lục

- [1. Yêu cầu hệ thống](#1-yêu-cầu-hệ-thống)
- [2. Cài đặt Rust](#2-cài-đặt-rust)
- [3. Cài đặt Arkworks](#3-cài-đặt-arkworks)
- [4. Cấu trúc project](#4-cấu-trúc-project)
- [5. Cách chạy thực nghiệm](#5-cách-chạy-thực-nghiệm)
- [6. Giải thích chi tiết `run_20m_circuit.sh`](#6-giải-thích-chi-tiết-run_20m_circuitsh)
- [7. Phân tích kết quả](#7-phân-tích-kết-quả)
- [8. Xử lý lỗi thường gặp](#8-xử-lý-lỗi-thường-gặp)

---

## 1. Yêu cầu hệ thống

| Thành phần | Yêu cầu tối thiểu | Khuyến nghị (AsusL40) |
|------------|--------------------|-----------------------|
| **OS** | Linux (Ubuntu 20.04+) | Ubuntu 22.04 LTS |
| **CPU** | x86_64, ≥ 8 cores | Xeon Gold 6538Y+, 16 vCPU |
| **RAM** | ≥ 64 GiB | 200 GiB |
| **RAM trống** | ≥ 128 GiB (proving cần ~60 GiB + PK + witness) | 128 GiB+ |
| **Disk** | ≥ 20 GiB trống | SSD khuyến nghị |
| **Rust** | ≥ 1.70.0 | Stable mới nhất |
| **GCC/Clang** | ≥ 9.0 | ≥ 11.0 |

> **Lưu ý:** Script sử dụng `/usr/bin/time -v` (GNU time), **không** chạy được trên macOS hay Windows.  
> Trên macOS, cài `gtime` qua Homebrew: `brew install gnu-time`, rồi thay `/usr/bin/time` bằng `gtime`.

---

## 2. Cài đặt Rust

### 2.1. Cài Rust qua rustup

```bash
# Tải và chạy rustup installer
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

Khi được hỏi, chọn **1) Proceed with standard installation (default)**.

```bash
# Load biến môi trường Rust (hoặc mở terminal mới)
source $HOME/.cargo/env

# Kiểm tra cài đặt thành công
rustc --version     # Output: rustc 1.xx.x (xxxxxxx yyyy-mm-dd)
cargo --version     # Output: cargo 1.xx.x (xxxxxxx yyyy-mm-dd)
```

### 2.2. Cài dependencies hệ thống

**Ubuntu / Debian:**
```bash
sudo apt update
sudo apt install -y \
    build-essential \
    pkg-config \
    libssl-dev \
    cmake \
    git \
    time            # GNU time (cung cấp /usr/bin/time -v)
```

**CentOS / RHEL / Fedora:**
```bash
sudo yum install -y \
    gcc gcc-c++ \
    openssl-devel \
    cmake make \
    git \
    time
```

### 2.3. Cập nhật Rust (nếu đã cài từ trước)

```bash
rustup update stable
rustup default stable
```

---

## 3. Cài đặt Arkworks

Arkworks **không cần cài riêng** — nó là một bộ thư viện Rust, được quản lý qua `Cargo.toml`. Khi bạn chạy `cargo build`, Cargo sẽ tự động tải và biên dịch các crate Arkworks.

### 3.1. Các crate Arkworks cần thiết

Trong file `Cargo.toml` của project, các dependency chính là:

| Crate | Vai trò |
|-------|---------|
| `ark-ff` | Finite field arithmetic (phép toán trên trường hữu hạn) |
| `ark-ec` | Elliptic curve operations (phép toán đường cong) |
| `ark-poly` | Polynomial operations |
| `ark-groth16` | Groth16 proving system (tạo và verify ZKP) |
| `ark-bn254` | Đường cong BN254 (128-bit security, tương thích EVM) |
| `ark-r1cs-std` | Gadgets cho hệ ràng buộc R1CS |
| `ark-crypto-primitives` | Hash functions (Poseidon), commitment schemes |
| `ark-std` | Utilities (RNG, parallelism) |
| `ark-serialize` | Serialisation cho keys, proofs |
| `ark-snark` | SNARK trait interface |

### 3.2. Feature `parallel`

Feature `parallel` là tính năng quan trọng nhất — nó bật **Rayon-based parallelism** cho tất cả các crate Arkworks, cho phép tận dụng nhiều CPU cores:

```toml
# Trong Cargo.toml
[features]
parallel = [
    "ark-std/parallel",
    "ark-ff/parallel",
    "ark-ec/parallel",
    "ark-poly/parallel",
    "ark-groth16/parallel",
    "ark-r1cs-std/parallel",
    "ark-crypto-primitives/parallel",
]
```

Khi build với `--features parallel`, Arkworks sẽ:
- Sử dụng **Rayon** để song song hoá multi-scalar multiplication (MSM)
- Song song hoá FFT/NTT trong polynomial evaluation
- Song song hoá witness assignment
- Tự động sử dụng tất cả CPU cores có sẵn

**Không bật `parallel`:** prover chạy single-threaded, chậm hơn 4-8× trên CPU 16 cores.

### 3.3. Build lần đầu

```bash
cd HZKA/scripts/circuit_20m

# Build release mode với parallel feature
# Lần đầu sẽ download + compile tất cả dependencies (~5-15 phút)
cargo build --release --features parallel
```

> **Tip:** Lần build đầu tiên lâu vì Cargo phải compile toàn bộ Arkworks (~200+ crates).  
> Các lần build sau sẽ nhanh hơn nhiều vì Cargo cache các artifact.

### 3.4. Kiểm tra Arkworks hoạt động

```bash
# Chạy thử binary build_agg với --help
cargo run --release --features parallel --bin build_agg -- --help

# Output mong đợi:
# Build the H-ZKA aggregation circuit
#
# Usage: build_agg [OPTIONS]
#
# Options:
#       --slots <SLOTS>                Number of inner proof slots [default: 15]
#       --public-inputs <PUBLIC_INPUTS> ...
#       --out <OUT>                    Output directory
#   -h, --help                         Print help
```

---

## 4. Cấu trúc project

```
HZKA/scripts/circuit_20m/
├── Cargo.toml              # Dependencies và feature flags
├── run_20m_circuit.sh      # Script chạy 5 bước proving pipeline
├── parse_20m_results.py    # Python script parse kết quả
├── input_full.json         # Input data cho witness generation
└── src/
    ├── lib.rs              # Library root
    ├── aggregation.rs      # Mạch tổng hợp (B_max inner proofs)
    ├── commitment.rs       # Poseidon commitment
    ├── utils.rs            # Timing, file utilities
    └── bin/
        ├── build_agg.rs    # Binary: sinh R1CS + proving key + verifying key
        ├── witness.rs      # Binary: sinh witness từ input data
        ├── prove.rs        # Binary: tạo Groth16 proof
        └── verify.rs       # Binary: xác minh proof
```

### Kết quả output (sau khi chạy)

```
HZKA/result/circuit_20M/
├── host_info.txt           # Thông tin máy (uname, lscpu, free)
├── build_agg/              # Circuit artifacts
│   ├── agg.r1cs            # Mô tả hệ ràng buộc R1CS
│   ├── agg_pk.bin          # Groth16 Proving Key (~vài GiB)
│   ├── agg_vk.bin          # Groth16 Verifying Key (~vài KiB)
│   └── build_log.txt       # Constraint count, timing
├── constraint_count.txt    # Số constraint thực tế
├── identity_hashes.txt     # SHA-256 của R1CS, PK, VK
├── deps.lock.txt           # Cargo dependency tree
├── witness.bin             # Generated witness
├── witness.time            # Timing cho witness generation
├── proof_1.bin             # Proof run 1
├── proof_2.bin             # Proof run 2
├── proof_3.bin             # Proof run 3
├── prove_1.time            # /usr/bin/time -v output run 1
├── prove_2.time            # /usr/bin/time -v output run 2
├── prove_3.time            # /usr/bin/time -v output run 3
├── public_1.json           # Public inputs từ verifier
├── manifest.txt            # Metadata tổng hợp
└── measured_summary.json   # Mean/CI (từ parse_20m_results.py)
```

---

## 5. Cách chạy thực nghiệm

### 5.1. Chạy tự động (khuyến nghị)

```bash
# SSH vào máy AsusL40
ssh user@asusl40

# Di chuyển đến thư mục project
cd HZKA/scripts/circuit_20m

# Chạy toàn bộ pipeline
bash run_20m_circuit.sh
```

Script sẽ tự động thực hiện 5 bước và lưu kết quả vào `HZKA/result/circuit_20M/`.

### 5.2. Chạy từng bước thủ công

Nếu muốn kiểm soát từng bước:

```bash
cd HZKA/scripts/circuit_20m
RESULT_DIR="../../result/circuit_20M"
mkdir -p "${RESULT_DIR}"

# Bước 1: Build mạch
cargo run --release --features parallel --bin build_agg -- \
    --slots 15 --public-inputs commitment --out "${RESULT_DIR}/build_agg/"

# Bước 2: Ghi nhận identity
sha256sum "${RESULT_DIR}/build_agg/agg.r1cs" \
          "${RESULT_DIR}/build_agg/agg_pk.bin" \
          "${RESULT_DIR}/build_agg/agg_vk.bin" \
    | tee "${RESULT_DIR}/identity_hashes.txt"
cargo tree --locked > "${RESULT_DIR}/deps.lock.txt"

# Bước 3: Witness generation (có đo thời gian)
/usr/bin/time -v cargo run --release --features parallel --bin witness -- \
    --circuit "${RESULT_DIR}/build_agg/agg.r1cs" \
    --input input_full.json \
    --out "${RESULT_DIR}/witness.bin" \
    2>"${RESULT_DIR}/witness.time"

# Bước 4: Proving (3 lần, có đo thời gian + RAM)
for i in 1 2 3; do
    /usr/bin/time -v cargo run --release --features parallel --bin prove -- \
        --pk "${RESULT_DIR}/build_agg/agg_pk.bin" \
        --witness "${RESULT_DIR}/witness.bin" \
        --out "${RESULT_DIR}/proof_${i}.bin" \
        2>"${RESULT_DIR}/prove_${i}.time"
done

# Bước 5: Verify
cargo run --release --bin verify -- \
    --vk "${RESULT_DIR}/build_agg/agg_vk.bin" \
    --proof "${RESULT_DIR}/proof_1.bin" \
    --public "${RESULT_DIR}/public_1.json"
```

### 5.3. Điều chỉnh số Rayon threads

Mặc định, Rayon sử dụng tất cả CPU cores. Để giới hạn:

```bash
# Giới hạn 8 threads
RAYON_NUM_THREADS=8 bash run_20m_circuit.sh

# Hoặc khi chạy thủ công
RAYON_NUM_THREADS=8 cargo run --release --features parallel --bin prove -- ...
```

---

## 6. Giải thích chi tiết `run_20m_circuit.sh`

| Bước | Lệnh chính | Mục đích | Output |
|------|-----------|----------|--------|
| **1. Build** | `cargo run --bin build_agg -- --slots 15 --public-inputs commitment` | Biên dịch mạch R1CS + sinh proving/verifying key | `agg.r1cs`, `agg_pk.bin`, `agg_vk.bin` |
| **2. Identity** | `sha256sum` + `cargo tree --locked` | Ghi nhận hash artifacts + dependency tree | `identity_hashes.txt`, `deps.lock.txt` |
| **3. Witness** | `/usr/bin/time -v cargo run --bin witness` | Sinh witness từ input data, đo thời gian | `witness.bin`, `witness.time` |
| **4. Prove ×3** | `/usr/bin/time -v cargo run --bin prove` (×3 lần) | Tạo 3 proof độc lập, đo wall-clock + peak RSS | `proof_{1,2,3}.bin`, `prove_{1,2,3}.time` |
| **5. Verify** | `cargo run --bin verify` | Kiểm tra proof hợp lệ, ghi public inputs | `public_1.json` |

### Tại sao prove 3 lần?

- Để tính **mean** (trung bình) và **95% confidence interval** (CI)
- Loại bỏ nhiễu từ OS scheduling, cache warming, v.v.
- 3 runs là mức tối thiểu để có CI với phân phối t-distribution

### `/usr/bin/time -v` đo gì?

```
# Output mẫu từ prove_1.time:
Command being timed: "cargo run ..."
Elapsed (wall clock) time (h:mm:ss or m:ss): 1:32.45    ← Thời gian thực
Maximum resident set size (kbytes): 62914560              ← Peak RAM (bytes)
Average resident set size (kbytes): 45000000              ← RAM trung bình
Percent of CPU this job got: 1280%                        ← % CPU (>100% = parallel)
Major (requiring I/O) page faults: 0
Minor (reclaiming a frame) page faults: 15000000
Voluntary context switches: 1200
Involuntary context switches: 5000
```

---

## 7. Phân tích kết quả

Sau khi `run_20m_circuit.sh` hoàn tất:

```bash
# Chạy script phân tích (Python, chạy được ở bất kỳ máy nào)
cd HZKA/scripts/circuit_20m
python3 parse_20m_results.py --result-dir ../../result/circuit_20M
```

Script sẽ:
1. Parse 3 file `prove_{1,2,3}.time` → tính mean và 95% CI
2. Parse `witness.time` → thời gian witness generation
3. So sánh kết quả đo được với 3 model dự đoán (Table 21)
4. Cập nhật bảng E8 pipeline với giá trị S_agg thực đo

Output:
```
  Proving time:  92.3 ± 3.1 s  (n=3)
  Peak RSS:      58.2 GiB  (n=3)

  Model validation (Table 21):
    Model                         predicted  measured  error   rel.error
    Linear                           90.2      92.3   +2.1     +2.3%
    Quasilinear                     108.3      92.3  -16.0    -14.8%
    Interval low (sublinear)         54.6      92.3  +37.7    +69.0%
    Interval high                   122.5      92.3  -30.2    -24.7%
```

---

## 8. Xử lý lỗi thường gặp

### Lỗi: `error: linker cc not found`
```bash
# Thiếu build tools
sudo apt install -y build-essential
```

### Lỗi: `error: failed to run custom build command for openssl-sys`
```bash
# Thiếu OpenSSL development headers
sudo apt install -y libssl-dev pkg-config
```

### Lỗi: `thread 'main' panicked at 'memory allocation failed'`
```bash
# Không đủ RAM. Kiểm tra:
free -h
# Cần ≥ 128 GiB RAM trống cho B_max=15

# Giải pháp tạm: giảm B_max (nhưng không khớp manuscript)
cargo run --release --features parallel --bin build_agg -- --slots 5 --out ./test/
```

### Lỗi: `/usr/bin/time: not found`
```bash
# Cài GNU time
sudo apt install -y time

# Trên macOS:
brew install gnu-time
# Rồi thay /usr/bin/time bằng gtime trong script
```

### Lỗi: `Killed` (OOM Killer)
```bash
# OS đã kill process vì hết RAM
# Kiểm tra dmesg:
dmesg | tail -20

# Giải pháp: tăng swap hoặc dùng máy có nhiều RAM hơn
sudo fallocate -l 64G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
```

### Build quá chậm
```bash
# Tăng tốc build bằng sccache (build cache)
cargo install sccache
export RUSTC_WRAPPER=sccache

# Hoặc dùng mold linker (nhanh hơn ld)
sudo apt install -y mold
RUSTFLAGS="-C link-arg=-fuse-ld=mold" cargo build --release --features parallel
```

---

## Tài liệu tham khảo

- [Rust Installation Guide](https://www.rust-lang.org/tools/install)
- [Arkworks GitHub](https://github.com/arkworks-rs) — Bộ thư viện ZKP chính
- [Arkworks Tutorial](https://github.com/arkworks-rs/r1cs-tutorial) — Hướng dẫn viết mạch R1CS
- [BN254 Curve](https://hackmd.io/@jpw/bn254) — Chi tiết đường cong BN254
- [Groth16 Paper](https://eprint.iacr.org/2016/260) — Jens Groth, 2016
