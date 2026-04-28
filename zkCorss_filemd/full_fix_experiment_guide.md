# Hướng dẫn sửa lỗi và thực nghiệm zkCross

Tài liệu này mô tả đầy đủ cách xử lý lỗi, kiểm tra code và chạy thực nghiệm cho dự án `Project/zkCross`.
Nội dung đặc biệt chú trọng vào 3 bước cuối cùng: chạy thử nghiệm, thu thập kết quả, và cập nhật báo cáo.

## 1. Tổng quan

Mục tiêu chính:
- Khắc phục sai sót thực nghiệm lớn nhất: phần công bố chi phí Groth16 verifier không chính xác.
- Hoàn thiện các sửa lỗi bảo mật B2/B3 trong hợp đồng `ClusterManager.sol` và `ReputationRegistry.sol`.
- Đảm bảo hệ thống có thể tái hiện qua thử nghiệm, kiểm thử và cả báo cáo.

Các vấn đề chính:
- `B1` — Claim `~40K constraints` cho Groth16 verifier là sai; thực tế ~20M constraints.
- `B2` — Cần kiểm chứng VRF cluster reshuffle + Data Availability challenge.
- `B3` — Cần kiểm chứng slashing, non-linear penalty, appeal và cách ly Byzantine.
- Cảnh báo compile / tham số chưa dùng trong Solidity.
- Test chưa đủ cho các hành vi bảo mật và thực nghiệm.

## 2. Chuẩn bị môi trường

### 2.1 Yêu cầu phần mềm

Cài đặt sẵn trên máy LOCAL:
- Node.js / npm
- Python 3
- `npx` / `snarkjs`
- Docker (cho VM nếu cần)
- `git`

### 2.2 Cấu trúc thư mục chính

```
Project/zkCross/
  ├── contracts/
  │   └── audit_chain/
  │       ├── ClusterManager.sol
  │       └── ReputationRegistry.sol
  ├── scripts/
  │   ├── mfpop_simulation.py
  │   ├── groth16_ram_benchmark.cjs
  │   ├── deploy_contracts_v2.cjs
  │   ├── real_workload_experiment.cjs
  │   └── network_latency_experiment.sh
  ├── docs/
  │   └── full_fix_experiment_guide.md
  ├── results/
  └── zkp/
```

### 2.3 Kiểm tra trạng thái ban đầu

```bash
cd /home/mihwuan/Project/zkCross
git status --short
```

Nếu có thay đổi chưa commit, lưu lại hoặc tạm stash trước khi sửa.

## 3. Sửa lỗi và kiểm chứng code

### 3.1 Khắc phục B1: benchmark Groth16 thực tế

#### 3.1.1 Mục tiêu

- Xác nhận lại chi phí Groth16 verifier Solidity.
- Ghi nhận điều kiện thực nghiệm và dữ liệu RAM/thời gian thật.

#### 3.1.2 Cách chạy

```bash
cd /home/mihwuan/Project/zkCross
node scripts/groth16_ram_benchmark.cjs
```

#### 3.1.3 Kết quả mong đợi

- File `results/groth16_real_report.json` hoặc `results/ram_benchmark/...` được tạo.
- Log hiển thị constraint count, RAM, time.
- Nếu output vẫn còn claim sai lệch, cần sửa script và báo cáo.

### 3.2 Khắc phục B2/B3: hợp đồng và thiết kế hệ thống

#### 3.2.1 Kiểm tra file sửa lỗi

- `contracts/audit_chain/ClusterManager.sol`
- `contracts/audit_chain/ReputationRegistry.sol`

#### 3.2.2 Nội dung cần thao tác

- Xác nhận các sửa lỗi `SỬA LỖI B2` và `SỬA LỖI B3` đã được hiện thực hóa trên code.
- Đảm bảo:
  - VRF shuffle thực sự xáo trộn `allChainIds` mỗi epoch.
  - Challenge window `CHALLENGE_WINDOW` hoạt động.
  - Slashing dựa trên `MIN_STAKE`, `SLASH_PERCENT`, `SLASH_MULTIPLIER`.
  - Appeal có thể nộp và resolve.

#### 3.2.3 Dọn cảnh báo Solidity

Tìm và sửa các warning:
- `Unused function parameter`
- `state variable not used`

Ví dụ:
- `contracts/audit_chain/AuditContract.sol`
- `contracts/audit_chain/ReputationRegistry.sol`

Nếu tham số hàm có tên nhưng không dùng, hãy comment tên hoặc dùng `_`.

### 3.3 Tăng cường kiểm thử

#### 3.3.1 Test hợp đồng

Thêm hoặc mở rộng test cho:
- `ClusterManager.sol`:
  - `reshuffleClusters`
  - `fileDAChallenge`
  - `resolveDAChallenge`
  - `chainSubmittedInRound`
- `ReputationRegistry.sol`:
  - `updateReputation` với `consistent = false`
  - `appeal` và `resolveAppeal`
  - `withdrawStake`

#### 3.3.2 Test mô phỏng MF-PoP

Chạy script mô phỏng:

```bash
python3 scripts/mfpop_simulation.py
```

Xác nhận:
- Attacker bị cô lập sau ~46 rounds.
- Accuracy recovery chart và reputation chart được tạo ra.
- Dữ liệu `results/mfpop_simulation_data.json` tồn tại.

## 4. Chạy thử nghiệm thực tế

Đây là bước mấu chốt để chứng minh hệ thống hoạt động thay vì chỉ lý thuyết.

### 4.1 Chạy thử nghiệm LOCAL

#### 4.1.1 MF-PoP simulation

```bash
cd /home/mihwuan/Project/zkCross
python3 scripts/mfpop_simulation.py
```

#### 4.1.2 Groth16 RAM benchmark

```bash
cd /home/mihwuan/Project/zkCross
node scripts/groth16_ram_benchmark.cjs
```

#### 4.1.3 Sepolia deployment (nếu cần đo gas thật)

Tạo file `.env` chứa:

```bash
SEPOLIA_RPC_URL=https://rpc.sepolia.org
DEPLOYER_PRIVATE_KEY=0x_your_private_key
```

Rồi chạy:

```bash
cd /home/mihwuan/Project/zkCross
node scripts/deploy_sepolia.cjs
```

### 4.2 Chạy thử nghiệm trên VM

#### 4.2.1 Chuẩn bị VM

Trên mỗi VM:

```bash
cd /home/mihwuan/Project/zkCross
bash scripts/azure_vm_setup.sh
```

#### 4.2.2 Khởi động Docker chain

```bash
cd /home/mihwuan/Project/zkCross/docker
cp .env.vm<VM_ID> .env
docker compose -f docker-compose-10vm.yml up -d --build
```

#### 4.2.3 Triển khai hợp đồng local

```bash
cd /home/mihwuan/Project/zkCross
VM_ID=<VM_ID> node scripts/deploy_contracts_v2.cjs
```

#### 4.2.4 Chạy workload và latency

```bash
cd /home/mihwuan/Project/zkCross
VM_ID=<VM_ID> node scripts/real_workload_experiment.cjs
VM_ID=<VM_ID> node scripts/real_latency_experiment.cjs
```

#### 4.2.5 Thử nghiệm mạng thực tế

```bash
cd /home/mihwuan/Project/zkCross
sudo bash scripts/network_latency_experiment.sh
```

### 4.3 Kết quả phải ghi nhận

Đảm bảo các file kết quả sau được tạo:
- `results/groth16_real_report.json`
- `results/mfpop_simulation_data.json`
- `results/ram_benchmark/*`
- `results/workload/*`
- `results/latency/*`
- `results/network_latency/*`

## 5. Thu thập và đối chiếu kết quả (3 bước cuối quan trọng)

### 5.1 Bước 1: Thu thập dữ liệu thực nghiệm đầy đủ

Ghi nhận từng dữ liệu sau:
- Số lượng constraint thực tế của Groth16 verifier.
- RAM và thời gian prove/verify của các circuit.
- Các chỉ số reputation: `R_min`, `round isolation`, attacker drop.
- Latency và throughput trong môi trường Docker/VM.
- Kết quả chi phí gas nếu triển khai Sepolia.

Lưu ý: dùng file `results/*.json` để tổng hợp, không dùng dữ liệu đoán chừng.

### 5.2 Bước 2: So sánh với báo cáo hiện tại và sửa tài liệu

Cần đối chiếu với các tuyên bố hiện tại trong:
- `Project/zkCross/README.md`
- `docs/circuit_compilation_guide.md`
- `contracts/*` comment mô tả
- Báo cáo giấy tờ nếu có copy trong `zkCross_filemd` hoặc `Papers`

Sửa các khẳng định sai:
- “~40K constraints” → “~20M constraints cho Solidity verifier”
- “Xây dựng recursive verifier chi phí thấp” nếu chưa được xác thực.
- “Các giả định chạy được trên 200 nodes” nếu chưa có thử nghiệm tương ứng.

### 5.3 Bước 3: Hoàn thiện và bàn giao kết quả

Hoàn thành các phần sau:
- Cập nhật README/guide với lệnh thực thi và kết quả đầu ra.
- Ghi rõ môi trường chạy (CPU, RAM, OS, Docker version, Node version).
- Ghi rõ những giới hạn còn tồn tại:
  - nếu circuit quá lớn cần bộ nhớ cao,
  - nếu benchmark trên VM chỉ là mô phỏng nội bộ,
  - nếu Sepolia chỉ đo gas cho một số hàm.

Nếu cần, tạo thêm file báo cáo ngắn trong `docs/` hoặc `results/` gồm:
- Tóm tắt vấn đề đã sửa.
- Các bước đã thực hiện.
- Kết luận chính xác của thực nghiệm.

## 6. Checklist hoàn chỉnh

- [ ] Đã chạy `node scripts/groth16_ram_benchmark.cjs` và thu được `results`.
- [ ] Đã chạy `python3 scripts/mfpop_simulation.py` và xác nhận attacker bị cô lập.
- [ ] Đã sửa cảnh báo Solidity `Unused parameter`.
- [ ] Đã kiểm tra `ClusterManager.sol` và `ReputationRegistry.sol` theo B2/B3.
- [ ] Đã chạy `node scripts/real_workload_experiment.cjs` trên VM.
- [ ] Đã chạy `node scripts/real_latency_experiment.cjs` trên VM.
- [ ] Đã chạy `bash scripts/network_latency_experiment.sh` với tc/netem.
- [ ] Đã update README và docs với dữ liệu thực nghiệm chính thức.

## 7. Ghi chú thêm

- Nếu các bước chạy trên VM gặp lỗi Docker hoặc mạng, lưu log vào `scripts/log_run_script/`.
- Nếu `npx snarkjs` không chạy, cài lại dependency bằng `npm install` trong `Project/zkCross`.
- Nếu cần chạy lại toàn bộ hơn, đặt lại condition bằng:
  - `rm -rf results/*`
  - `git checkout -- contracts/audit_chain/*.sol`

---

Tài liệu này là hướng dẫn hoàn chỉnh để sửa lỗi, chạy thực nghiệm và bàn giao kết quả cho dự án `zkCross`.
