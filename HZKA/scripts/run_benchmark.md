# Báo cáo Cập nhật Benchmarking H-ZKA (Thuần CPU trên máy chủ DGX)


## Cấu hình Hệ thống & Môi trường Thực nghiệm (Experimental Setup)

Để đảm bảo tính công bằng và khả năng tái lập (reproducibility) của quá trình đánh giá hiệu năng, toàn bộ các bài test Benchmark cho hệ thống H-ZKA được thực hiện trên một node tính toán hiệu năng cao (HPC Compute Node) quản lý bởi SLURM Workload Manager. Quá trình sinh bằng chứng (Proving) được cấu hình chạy thuần túy trên vi xử lý trung tâm (CPU).

Chi tiết cấu hình phần cứng và phần mềm cụ thể như sau:

**Cấu hình Phần cứng (Hardware Specifications):**
* **Máy chủ (Node):** AsusL40 (Kiến trúc x86_64)
* **Vi xử lý (CPU):** Intel(R) Xeon(R) Gold 6538Y+
* **Tài nguyên cấp phát (Allocated Resources):** 16 vCPUs (Sử dụng kiến trúc đa luồng).
* **Bộ nhớ hệ thống (System RAM):** 200 GB.
* **Gia tốc phần cứng (GPU):** Không kích hoạt.

**Môi trường Phần mềm (Software Environment):**
* **Hệ điều hành:** Linux (Ubuntu/Debian-based x64).
* **Trình biên dịch Mạch (Circuit Compiler):** Circom (Latest Master branch từ Iden3). Hệ thống sử dụng cờ `--wasm` để sinh định dạng WebAssembly 32-bit cho giai đoạn khởi tạo Witness.
* **Môi trường Runtime (JS):** Node.js v20.12.2 (với cờ mở rộng bộ nhớ ảo `--max-old-space-size=163840`).
* **Công cụ sinh Bằng chứng (Rust Prover - Arkworks):** 
  * Ngôn ngữ thực thi: Rust (Phiên bản Stable mới nhất cập nhật qua `rustup`).
  * Giao thức Zero-Knowledge: Groth16.
  * Thư viện mật mã (Cryptography Libraries): Cấu hình cứng phiên bản `v0.6.0` cho toàn bộ hệ sinh thái Arkworks bao gồm `ark-bn254`, `ark-groth16`, `ark-snark`, và `ark-circom`.
  * Tối ưu hóa tính toán: Kích hoạt tính năng xử lý song song (`features = ["parallel"]`) trong thư viện `ark-groth16`, kết hợp với biến môi trường `RAYON_NUM_THREADS = 16` để khai thác tối đa sức mạnh của 16 vCPU.

> **Phương pháp đo lường:** Mỗi kích thước mạch (số lượng Constraints) được kiểm thử độc lập 3 vòng lặp (Iterations = 3). Thời gian Prover được ghi nhận nội bộ bên trong mã nguồn Rust (đo bằng đối tượng `std::time::Instant`), loại trừ các độ trễ liên quan đến I/O đọc/ghi file từ ổ cứng, đảm bảo phản ánh chính xác hiệu năng tính toán thuật toán mật mã của CPU.


## Xử lý Dữ liệu Thời gian Prover 

=======================================================================
    Mạch      | Lần 1 (s) | Lần 2 (s) | Lần 3 (s) | Trung Bình (s)
-----------------------------------------------------------------------
    0.5M      |     2.848 |     2.721 |     3.045 |       2.871
    1.0M      |     5.044 |     5.358 |     4.512 |       4.971
    2.0M      |     8.183 |     8.887 |     8.331 |       8.467  
    4.0M      |    16.552 |    16.017 |    15.500 |      16.023
    5.0M      |    23.112 |    20.588 |    20.707 |      21.469
    8.0M      |    29.870 |    26.404 |    26.122 |      27.465
   10.0M      |    39.430 |    41.367 |    45.261 |      42.019
   11.0M      |    50.031 |    53.116 |    48.384 |      50.510
   11.5M      |    62.007 |    58.172 |    53.400 |      57.860
=======================================================================

Dựa trên kết quả chạy thực nghiệm trên máy chủ DGX, dữ liệu thô được tính toán Giá trị trung bình (Mean) và Độ lệch chuẩn (Standard Deviation) như sau:

* **0.5M:** [2.848, 2.721, 3.045] $\rightarrow$ **2.87 ± 0.16 s**
* **1.0M:** [5.044, 5.358, 4.512] $\rightarrow$ **4.97 ± 0.43 s**
* **2.0M:** [8.183, 8.887, 8.331] $\rightarrow$ **8.47 ± 0.37 s**
* **4.0M:** [16.552, 16.017, 15.500] $\rightarrow$ **16.02 ± 0.52 s**
* **5.0M:** [23.112, 20.588, 20.707] $\rightarrow$ **21.47 ± 1.42 s**
* **8.0M:** [29.870, 26.404, 26.122] $\rightarrow$ **27.47 ± 2.08 s**
* **10.0M:** [39.430, 41.367, 45.261] $\rightarrow$ **42.02 ± 2.96 s**
* **11.0M:** [50.031, 53.116, 48.384] $\rightarrow$ **50.51 ± 2.40 s**
* **11.5M:** [62.007, 58.172, 53.400] $\rightarrow$ **57.86 ± 4.31 s**


### Ngoại suy tuyến tính (Linear Regression) cho mốc 20M:
Sử dụng phương pháp bình phương tối thiểu (Least Squares Method) dựa trên 9 điểm dữ liệu thực nghiệm:
* Biến độc lập $X$: Số lượng constraints (Triệu).
* Biến phụ thuộc $Y$: Thời gian Prover trung bình (s).

Phương trình hồi quy: 
$$Y = mX + c$$

Với các hệ số điều chỉnh mới khi tính đến mức rào cản tài nguyên của WASM ở 11M+:
* $m \approx 4.568$
* $c \approx -1.159$

Thời gian dự kiến cho mạch 20M Constraints:
$$Y(20) = 4.568 \times 20 - 1.159 \approx 90.19 \text{ (s)}$$

---

### Bảng 13 
**Table 13:** Sequential Proving Time Benchmarks for Groth16 (Measured on DGX Server - 16 vCPU, 200GB RAM). The 20 M-constraint time is extrapolated via linear regression over 9 data points.

| Constraints | Mean Prover Time (s) | Note |
| :--- | :--- | :--- |
| 500,000 | 2.87 ± 0.16 | Measured (3 runs) |
| 1,000,000 | 4.97 ± 0.43 | Measured (3 runs) |
| 2,000,000 | 8.47 ± 0.37 | Measured (3 runs) |
| 4,000,000 | 16.02 ± 0.52 | Measured (3 runs) |
| 5,000,000 | 21.47 ± 1.42 | Measured (3 runs) |
| 8,000,000 | 27.47 ± 2.08 | Measured (3 runs) |
| 10,000,000 | 42.02 ± 2.96 | Measured (3 runs) |
| 11,000,000 | 50.51 ± 2.40 | Measured (3 runs) |
| 11,500,000 | 57.86 ± 4.31 | Measured (3 runs) |
| **20,000,000** | **$\approx$ 90.19** | **Extrapolated** |


> **Phân tích Hiệu năng:** SSức mạnh đa luồng của phần cứng DGX mang lại sự khác biệt rõ rệt (Thời gian Prover 20M giảm từ 641.9s xuống chỉ còn 90.19s, **tăng tốc hơn 7.1 lần**).

---

## Đánh giá Độ trễ End-to-End (E2E Latency) trên Hệ thống HPC

Để đảm bảo tính công bằng (Apples-to-Apples comparison), thời gian E2E của cả hai kiến trúc H-ZKA và zkCross đều được ngoại suy (extrapolated) dựa trên mô hình hồi quy tuyến tính thu được từ thực nghiệm trên máy chủ DGX (16 vCPU, 200GB RAM). 

**Table 10:** End-to-end round latency including off-chain proving (analytical model grounded in extrapolated prover and network measurements). *Both zkCross and H-ZKA are strictly evaluated on the same high-performance DGX hardware baseline.*

| $k$ | zkCross E2E (s) | H-ZKA E2E (s) | Slowdown |
| :---: | :---: | :---: | :---: |
| 25 | 55.8 ± 0.6 | **91.9 ± 0.5** | **1.65x** |
| 50 | 58.0 ± 0.9 | **92.8 ± 0.6** | **1.60x** |
| 100 | 61.4 ± 1.5 | **93.5 ± 0.8** | **1.52x** |
| 150 | 65.2 ± 2.0 | **94.5 ± 0.9** | **1.45x** |
| 200 | 68.6 ± 2.4 | **95.2 ± 1.0** | **1.39x** |

**Hiệu năng Tương đối (Relative Slowdown):** H-ZKA tốn nhiều thời gian hơn do yêu cầu mạch xác minh tổng hợp (20M constraints) không đổi, trong khi mạch của zkCross nhỏ hơn. Tuy nhiên, độ dốc Slowdown giảm dần chứng minh rằng khi quy mô mạng lưới ($k$) càng lớn, kiến trúc tập trung của H-ZKA càng cho thấy khả năng chống chịu mở rộng tốt hơn so với zkCross.


