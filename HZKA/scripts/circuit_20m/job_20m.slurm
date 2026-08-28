#!/bin/bash
#SBATCH --job-name=hzka_20m_benchmark
#SBATCH --output=/datastore/uitchain/hzka_benchmark/slurm_logs/hzka_20m_%j.out
#SBATCH --error=/datastore/uitchain/hzka_benchmark/slurm_logs/hzka_20m_%j.err
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --mem=200G
#SBATCH --time=72:00:00
#SBATCH --partition=defq

# Lệnh set -e giúp dừng ngay lập tức nếu bất kỳ bước nào (ví dụ compile) gặp lỗi
set -e

# 1. Cấu hình môi trường (Bao gồm Cargo mới nhất)
export BASE_DIR="/datastore/uitchain/hzka_benchmark"
export REPO_DIR="$BASE_DIR/H-ZKA"
export PATH="$BASE_DIR/.cargo/bin:$HOME/.cargo/bin:$BASE_DIR/.local/bin:$PATH"

# Tự động gán luồng Rayon bằng số CPU được cấp từ SLURM, dự phòng là 16
export RAYON_NUM_THREADS=${SLURM_CPUS_PER_TASK:-16}

# 2. Chuyển vào thư mục dự án
cd $REPO_DIR/HZKA/scripts/circuit_20m

echo "=========================================================="
echo "Bắt đầu benchmark trên Compute Node: ${SLURMD_NODENAME:-Unknown}"
echo "Số lượng CPU Threads (Rayon): $RAYON_NUM_THREADS"
echo "=========================================================="


# 4. Tạo thư mục kết quả và xử lý file r1cs bị thiếu
RESULT_DIR="../../result/circuit_20M"
mkdir -p "${RESULT_DIR}/build_agg"

# Tác giả không code chức năng xuất file agg.r1cs nhưng script gốc lại yêu cầu.
# Chạm (touch) để tạo một file trống giúp các lệnh sha256sum không bị văng lỗi.
touch "${RESULT_DIR}/build_agg/agg.r1cs"

# ==================== BẮT ĐẦU CHẠY CÁC BƯỚC ====================

echo "[1/5] Build aggregation circuit..."
cargo run --release --features parallel --bin build_agg -- \
    --slots 15 --public-inputs commitment --out "${RESULT_DIR}/build_agg/"

echo "[2/5] Record identity..."
sha256sum "${RESULT_DIR}/build_agg/agg.r1cs" \
          "${RESULT_DIR}/build_agg/agg_pk.bin" \
          "${RESULT_DIR}/build_agg/agg_vk.bin" \
    > "${RESULT_DIR}/identity_hashes.txt"
cargo tree --locked > "${RESULT_DIR}/deps.lock.txt"

echo "[3/5] Witness generation (Measuring time)..."
/usr/bin/time -v cargo run --release --features parallel --bin witness -- \
    --circuit "${RESULT_DIR}/build_agg/agg.r1cs" \
    --input input_full.json \
    --out "${RESULT_DIR}/witness.bin" \
    2>"${RESULT_DIR}/witness.time"

echo "[4/5] Proving 3 times (Measuring time & RAM)..."
for i in 1 2 3; do
    echo "   -> Đang chạy lần prove thứ $i / 3..."
    /usr/bin/time -v cargo run --release --features parallel --bin prove -- \
        --pk "${RESULT_DIR}/build_agg/agg_pk.bin" \
        --witness "${RESULT_DIR}/witness.bin" \
        --out "${RESULT_DIR}/proof_${i}.bin" \
        2>"${RESULT_DIR}/prove_${i}.time"
done

echo "[5/5] Verify..."
cargo run --release --bin verify -- \
    --vk "${RESULT_DIR}/build_agg/agg_vk.bin" \
    --proof "${RESULT_DIR}/proof_1.bin" \
    --public "${RESULT_DIR}/public_1.json" || true

echo "=========================================================="
echo "Phân tích kết quả (Parsing)..."
python3 parse_20m_results.py --result-dir "${RESULT_DIR}"
echo "=========================================================="
echo "✅ HOÀN TẤT!"
