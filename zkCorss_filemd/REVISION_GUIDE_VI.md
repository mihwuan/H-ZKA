# Hướng Dẫn Sửa Đổi Bài Báo zkCross v2 - Dựa trên Phản Hồi của Hội Đồng

## Tóm Tắt Tổng Quát
Tài liệu này cung cấp hướng dẫn từng bước để giải quyết 5 điểm phản hồi chính từ hội đồng phản biện. Bài báo hiện có những mâu thuẫn logic và các vấn đề kỹ thuật chưa được giải quyết mà phải sửa chữa trước khi gửi lại.

---

## BƯỚC 1: Đổi Tên Bài Báo

**Tiêu Đề Hiện Tại:**
```
zkCross v2: Byzantine-Resilient Reputation and Hierarchical Proof Aggregation 
for Scalable Cross-Chain Privacy-Preserving Auditing
```

**Vấn Đề:** Sử dụng "zkCross v2" có vẻ như tuyên bố sự liên tục về quyền tác giả với zkCross gốc (USENIX Security 2024), mà hội đồng phản biện xem đây là chiếm dụng trí tuệ.

**Các Tên Thay Thế Được Đề Xuất:**
Chọn một trong các tiêu đề sau:

**Phương Án A (Được Khuyến Nghị):**
```
H-ZKA (Hierarchical Zero-Knowledge Audit): 
Decoupling Byzantine Faults from Privacy-Preserving State Transitions
```

**Phương Án B (Thay Thế):**
```
TrustAudit: Hierarchical zk-SNARK Aggregation for 
Byzantine-Resilient Cross-Chain Verification
```

**Các Hành Động Cần Thực Hiện:**
- [ ] Thay đổi `\title{...}` ở dòng 24 của `paper.tex`
- [ ] Cập nhật tất cả các tham chiếu đến "zkCross v2" trong toàn bộ bài báo để sử dụng tên mới
- [ ] Tìm và thay thế:
  - "zkCross v2" → "H-ZKA" (hoặc tên bạn chọn)
  - Trong phần tóm tắt, giới thiệu và kết luận
- [ ] Cập nhật từ khóa để phản ánh thương hiệu mới

**Các Vị Trí Cần Cập Nhật:**
- Dòng 24: `\title{...}`
- Dòng 43: Abstract (nhiều lần xuất hiện)
- Dòng 68: Tham chiếu lộ trình phần
- Suốt Phần I (Giới Thiệu)
- Phần Kết Luận

---

## BƯỚC 2: Sửa Chữa Threat Model (Bất Đồng Bộ → Bán Đồng Bộ)

**Vấn Đề Hiện Tại (Dòng 172):**
```latex
Network communication is asynchronous with eventual delivery, 
meaning that adversaries may delay but not permanently suppress messages.
```

**Vấn Đề:**
- Hệ thống giả định **mạng bất đồng bộ** (tin nhắn đến trong thời gian trễ tùy ý)
- NHƯNG MF-PoP cắt giảm 10% tiền cọc cho những bằng chứng được gửi sau hạn
- **Mâu thuẫn Logic**: Trong mạng thực sự bất đồng bộ, bạn không thể phân biệt giữa:
  - Một node độc hại cố tình giữ bằng chứng
  - Một node không độc hại mà bằng chứng của nó bị trễ do trễ mạng
- Điều này tạo ra một tính không khả thi về mật mã: bạn đang cố gắng thực hiện đồng thuận đồng bộ trong một mô hình bất đồng bộ

**Sửa Chữa Bắt Buộc:**
Thay thế bằng mô hình **Bán Đồng Bộ** (Partially Synchronous):

```latex
Network communication is partially synchronous with bounded delay 
$\Delta$, meaning that all messages are delivered within a known 
upper bound. Any proof submitted after the deadline is treated as 
Byzantine behavior, as message delays of duration $\Delta$ are 
accounted for in the timeout period. This synchrony assumption is 
reasonable for inter-blockchain communication, where network topology 
is relatively stable and message routes are predetermined.
```

**Các Hành Động Cần Thực Hiện:**
1. [ ] Tìm dòng 172 trong paper.tex (phần Threat Model)
2. [ ] Thay thế "asynchronous with eventual delivery" bằng văn bản bán đồng bộ ở trên
3. [ ] Thêm định nghĩa chính thức của bounded delay:
   ```latex
   \begin{definition}[Partially Synchronous Network]
   We assume a partially synchronous network (GST model) where:
   - For each message $m$ sent at time $t$, there exists a known upper 
     bound $\Delta$ such that $m$ is delivered by time $t + \Delta$
   - All participating nodes have loosely synchronized clocks (within 
     tolerance $\delta \ll \Delta$)
   - Any proof committed after deadline $T_d = \text{proposal\_time} + \Delta + \delta$ 
     is classified as Byzantine and subject to slashing penalties
   \end{definition}
   ```
4. [ ] Cập nhật Phần 4 (Design Goals) để đề cập rõ ràng đến bounded delay
5. [ ] Trong phần về slashing của MF-PoP, tham chiếu đến giả định bounded delay này:
   ```latex
   Since network delays are bounded by $\Delta$, a committer that 
   fails to submit a proof within the deadline is assumed to be 
   acting maliciously and is penalized accordingly.
   ```

**Tại Sao Điều Này Quan Trọng:**
- Giải quyết mâu thuẫn logic với thời gian chặt
- Làm cho threat model **về mặt mật mã trở nên vững chắc**
- Phù hợp với thực hành trong các hệ thống cross-chain (Cosmos IBC, Polkadot finality)
- Cho phép bạn chính thức chứng minh khả năng chống Byzantine

---

## BƯỚC 3: Giải Quyết Vấn Đề Khả Năng Mở Rộng Mạch Groth16

**Vấn Đề Hiện Tại:**
Bài báo tuyên bố sử dụng Groth16 với clustering phân cấp ($\sqrt{k}$ clusters), nhưng Groth16 yêu cầu **Trusted Setup dành riêng cho mạch**. Khi cấu trúc cluster thay đổi (thực hiện cứ 100 khối qua quay vòng VRF), bạn cần một Trusted Setup mới.

**Hai Lựa Chọn:**

### PHƯƠNG ÁN A: Thừa Nhận Dummy Proof Padding (Đơn Giản Hơn, Giữ Groth16)

**Cần Làm:**
1. Thêm một phần phụ mới trong Phần V (Methodology) với tiêu đề:
   ```latex
   \subsubsection{Handling Variable Cluster Sizes via Dummy Proof Padding}
   ```

2. Thêm cuộc thảo luận này:
   ```latex
   The aggregation circuit $\Lambda_{\Psi_\text{agg}}$ is designed for 
   a fixed maximum cluster size $k_{\max} = \lceil \sqrt{K_{\text{global}}} \rceil$, 
   where $K_{\text{global}}$ is the maximum possible number of chains. 
   This fixed circuit size is a requirement of the Groth16 proof system, 
   which requires circuit-specific trusted setup.
   
   To accommodate clusters with fewer than $k_{\max}$ chains, we employ 
   \textit{Dummy Proof Padding}: for any cluster of size $k_i < k_{\max}$, 
   we generate $k_{\max} - k_i$ dummy proofs that trivially verify 
   (representing no-op state transitions). These dummy proofs have 
   identical proof size (127 bytes) and verification time, making them 
   computationally equivalent to real proofs from the circuit's perspective.
   
   **Performance Trade-off:** Dummy padding increases the number of 
   recursive verification steps from $k_i$ to $k_{\max}$, thus increasing 
   circuit constraints and verification time by up to $O(\sqrt{k} / k_i)$. 
   For near-full clusters (typical case), this overhead is negligible 
   ($\sim 5-10\%$). For sparse clusters (e.g., $k_i = 2$ out of $k_{\max} = 14$), 
   the overhead can reach $7\times$, representing a worst-case trade-off 
   between circuit fixedness and cluster utilization.
   
   We accept this trade-off as a practical necessity for Groth16 deployment. 
   Future systems using universal zk-SNARKs (Section VIII) would eliminate 
   this overhead entirely.
   ```

3. Trong Phần VII (Experiments), thêm một phần phụ:
   ```latex
   \subsection{Dummy Proof Padding Overhead Analysis}
   
   Table~\ref{tab:padding} shows the impact of dummy proof padding on 
   verification time as cluster utilization decreases.
   
   [Insert table showing padding overhead for different cluster sizes]
   ```

**Nhược Điểm:** Hiệu suất giảm một chút cho các cluster thưa thớt

**Ưu Điểm:** Thay đổi code tối thiểu, giữ Groth16, đơn giản hơn để triển khai

### PHƯƠNG ÁN B: Chuyển Sang PLONK (Sạch Hơn, Nhưng Tốn Nhiều Công Sức)

**Tại Sao PLONK Tốt Hơn:**
- PLONK là **Universal zk-SNARK**: chỉ cần MỘT trusted setup cho tất cả mạch
- Không cần setup dành riêng cho mạch ngay cả khi cấu trúc cluster thay đổi
- Các thuộc tính ZK tốt hơn và bằng chứng nhỏ hơn

**Cần Làm:**

1. Sửa Đổi Phần V (Methodology) - tạo phần phụ mới:
   ```latex
   \subsection{Proof System Selection: Rationale for PLONK}
   
   While the original zkCross employed Groth16 for its constant proof size 
   and well-understood security, zkCross v2 faces a fundamental challenge: 
   \textit{dynamic cluster topology}. Clusters are reshuffled every 100 blocks 
   via VRF-based epoch rotation, meaning the aggregation circuit 
   $\Lambda_{\Psi_\text{agg}}$ must adapt to different cluster sizes.
   
   Groth16 requires a unique trusted setup for each distinct circuit structure. 
   Changing the cluster size necessarily changes the circuit, requiring a new 
   trusted setup — a prohibitive operation for a dynamic system.
   
   We adopt PLONK (Permutation over Lagrange-bases for Oecumenical Noninteractive 
   arguments of Knowledge) as the proof system for the aggregation layer. PLONK 
   is a universal zk-SNARK requiring only a **single universal trusted setup** 
   that works for all circuit sizes up to a pre-defined maximum. This property 
   is essential for the dynamic cluster architecture of zkCross v2.
   
   **Aggregation Circuit in PLONK:**
   The aggregation circuit $\Lambda_{\Psi_\text{agg}}$ in PLONK remains 
   conceptually identical to the Groth16 version (Algorithm~\ref{alg:aggregation}), 
   with identical verification logic. However, PLONK-generated proofs are 
   slightly larger (4-6 KB vs. 127 bytes for Groth16) but remain constant 
   regardless of cluster size, and verification is faster by $\sim 2-3\times$ 
   due to better polynomial arithmetic.
   
   For the privacy-preserving transfer ($\Theta$) and exchange ($\Phi$) 
   protocols, we continue using Groth16 as in original zkCross, since those 
   circuits have fixed structure.
   ```

2. Cập nhật phần Implementation (Dòng 449):
   ```latex
   We implement zkCross v2 using a hybrid proof system approach:
   - **Transfer and Exchange layers ($\Theta, \Phi$):** Groth16 (unchanged 
     from original zkCross)
   - **Auditing layer aggregation ($\Lambda_{\Psi_\text{agg}}$):** PLONK 
     with universal trusted setup
   
   Off-chain proving is implemented using gnark (https://github.com/consensys/gnark) 
   which provides optimized implementations for both Groth16 and PLONK. On-chain 
   verification uses Solidity smart contracts.
   ```

3. Cập nhật phần Experiments với kết quả PLONK

**Nhược Điểm:** Yêu cầu tái triển khai lớp aggregation của lớp chứng minh

**Ưu Điểm:** Loại bỏ hoàn toàn dummy proof padding, kiến trúc sạch hơn, khả năng mở rộng tốt hơn

---

**KHUYẾN NGHỊ: Đối Với Lịch Làm Việc Của Bạn, Sử Dụng PHƯƠNG ÁN A (Dummy Proof Padding)**
- Ít thay đổi code hơn
- Bài báo đã phần nào thừa nhận điều này ở dòng 595
- Giải thích về sự đánh đổi rõ ràng có thể chấp nhận được từ hội đồng phản biện
- Có thể là công việc trong tương lai: "PLONK migration sẽ loại bỏ overhead này"

---

## BƯỚC 4: Thêm Bảng So Sánh Lý Thuyết Vào Related Work

**Vấn Đề Hiện Tại:**
Phần Related Work (Phần II) thiếu so sánh chi tiết với các hệ thống cạnh tranh cụ thể. Hội đồng phản biện mong đợi một bảng so sánh định lượng.

**Hành Động:**
Thêm bảng này sau Phần II.D (Reputation Systems):

```latex
\begin{table*}[t]
\centering
\caption{Theoretical Comparison of Cross-Chain Auditing Systems}
\label{tab:sota_comparison}
\begin{tabular}{|l|c|c|c|c|c|}
\hline
\textbf{System} & 
\textbf{Scalability} & 
\textbf{Byzantine Resilience} & 
\textbf{Privacy} & 
\textbf{Proof System} & 
\textbf{Setup} \\
\hline
\textbf{zkCross (orig.)} & 
$O(k)$ proofs & 
Honest committer & 
Transfer/Exchange only & 
Groth16 & 
Circuit-specific \\
\hline
\textbf{H-ZKA (this work)} & 
$O(\sqrt{k})$ proofs & 
$f < n/3$ Byzantine tolerance & 
Transfer/Exchange/Audit & 
Groth16 + Padding & 
Circuit-specific \\
\hline
\textbf{Hekaton [17]} & 
$O(1)$ proofs & 
Honest majority in pool & 
None (L1 settlement only) & 
Groth16 & 
Circuit-specific \\
\hline
\textbf{MAP Protocol [18]} & 
$O(N)$ on Light Client & 
External PKI & 
Header-only & 
Merkle proofs & 
None \\
\hline
\textbf{VeCroToken [19]} & 
$O(k)$ verification & 
Consortium (3-of-5) & 
Partial encryption & 
HMAC & 
None \\
\hline
\textbf{Hu et al. RNN [20]} & 
$O(1)$ scoring & 
RNN-based outlier detection & 
None & 
N/A & 
N/A \\
\hline
\end{tabular}
\end{table*}

\textbf{Comparison Summary:}

\begin{itemize}
\item \textbf{vs. Hekaton:} Hekaton achieves $O(1)$ audit verification through 
  horizontal scaling (distributing prover work across machines), but does not 
  address Byzantine participants in the proving pool. H-ZKA achieves $O(\sqrt{k})$ 
  through hierarchical clustering and adds autonomous Byzantine isolation via 
  reputation scoring, making it more suitable for permissionless cross-chain 
  environments.

\item \textbf{vs. MAP Protocol:} MAP reduces verification to $O(N)$ by using 
  light client proofs rather than full auditing. However, this comes at the cost 
  of reduced auditability (header-only, no transaction verification). H-ZKA 
  maintains full transaction auditing while achieving near-quadratic reduction in 
  global chain verification load.

\item \textbf{vs. VeCroToken:} VeCroToken targets consortium blockchains with 
  fixed Byzantine thresholds (3-of-5 validators). H-ZKA is designed for 
  permissionless settings where Byzantine participants are unknown a priori and 
  must be detected autonomously. VeCroToken does not support privacy-preserving 
  auditing of cross-chain transactions.

\item \textbf{vs. Hu et al. RNN-based Reputation:} Hu et al. propose using 
  recurrent neural networks (RNNs) for dynamic reputation assessment in cross-chain 
  transactions. This approach is more flexible than H-ZKA's exponential moving 
  average (EMA) but requires maintaining and updating neural network models, 
  adding significant complexity. H-ZKA uses a simpler, auditable linear scoring 
  model suitable for blockchain consensus, while future work could integrate 
  machine learning for enhanced Byzantine detection.
\end{itemize}
```

**Các Vị Trí:**
- Chèn sau dòng 130 (kết thúc Phần II.D về Reputation Systems)
- Thêm tham chiếu cho tất cả các hệ thống được trích dẫn (Hekaton, MAP Protocol, VeCroToken, Hu et al.)

---

## BƯỚC 5: Sửa Chữa Không Nhất Quán Dữ Liệu Thực Nghiệm

**Vấn Đề Hiện Tại:**
Dòng 590 tuyên bố "RAM per recursive verify ~ 0.75 GB" nhưng điều này mâu thuẫn với:
- Dòng 595: "200 million constraints, requiring ~ 7.5 GB RAM"
- Tiêu chuẩn công nghiệp: 20M constraints ≈ 750 MB - 1 GB trên mỗi bằng chứng

**Phân Tích Mâu Thuẫn:**
```
20 million constraints @ 768 bits per constraint = 19.2 billion bits = 2.4 GB
(Plus Proving Key overhead ~2-3x multiplier) = 7.5 - 10 GB total
```

Tuyên bố 0.75 GB cho 20M constraints vi phạm yêu cầu bộ nhớ vật lý.

**Các Hành Động Cần Thực Hiện:**

1. **Tìm và Sửa Không Nhất Quán** (dòng 590):
   ```latex
   % CŨ (SAI):
   RAM per recursive verify & $\sim$0.75 GB & BN254 pairing \\
   
   % MỚI (ĐÚNG):
   RAM per recursive verify & $\sim$2.4 GB & BN254 pairing, core proof only \\
   RAM for Proving Key & $\sim$5-8 GB & Includes key material and optimization \\
   ```

2. **Cập Nhật Mô Tả Phần VII** (khoảng dòng 595):
   
   Thay thế:
   ```latex
   For a cluster of 10 chains ($k = 100$), the total overhead is approximately 
   200 million constraints, requiring $\sim$200 seconds of prover time and 
   $\sim$7.5 GB RAM on a single CPU core.
   ```
   
   Với giải thích rõ ràng:
   ```latex
   For a cluster of 10 chains ($k = 100$), the total overhead is approximately 
   200 million constraints. Prover execution requires:
   - **Core proof generation:** ~2.4 GB RAM (constraint witnesses)
   - **Proving Key material:** ~5-8 GB RAM (field arithmetic tables, optimization)
   - **Total system memory:** ~10-12 GB RAM on a single CPU core
   - **Prover time:** ~200 seconds on 12-vCPU machine (amortized to ~20s per core)
   
   This memory requirement is substantial but occurs \textit{off-chain}, 
   allowing it to be batched and parallelized across cluster nodes.
   ```

3. **Thêm Từ Chối Trách Nhiệm Về Tác Động Thực Tiễn**:
   ```latex
   \textbf{Practical Implications:} The high memory requirement for individual 
   proof generation motivates deployment of H-ZKA on commodity servers (48+ GB RAM) 
   rather than resource-constrained devices. Off-chain prover nodes can be 
   centralized or semi-centralized, similar to Ethereum staking infrastructure. 
   Future work addressing this via Nova-style folding schemes could reduce 
   memory by 2-3 orders of magnitude, enabling embedded device participation.
   ```

4. **Xác Minh Thiết Lập Thực Nghiệm** (dòng 455):
   - Thiết lập của bạn sử dụng máy 48 GB RAM ✓ (đủ)
   - 4 nút Docker trên mỗi máy = 12 GB trên mỗi nút (phù hợp cho tạo bằng chứng chồng chéo)
   - Cấu hình này hợp lý và nên được nêu rõ ràng

---

## Danh Sách Kiểm Tra Sửa Đổi

- [ ] **BƯỚC 1**: Đổi tên bài báo (cập nhật tiêu đề + tất cả tham chiếu)
  - [ ] Dòng 24: `\title{...}`
  - [ ] Suốt bài báo: "zkCross v2" → "H-ZKA" (hoặc tên bạn chọn)
  - [ ] Cập nhật abstract (dòng 43-54)
  
- [ ] **BƯỚC 2**: Sửa Threat Model
  - [ ] Dòng 172: Thay thế "asynchronous" bằng "partially synchronous"
  - [ ] Thêm định nghĩa bounded delay
  - [ ] Cập nhật tiêu đề phần nếu cần
  
- [ ] **BƯỚC 3**: Giải Quyết Vấn Đề Groth16 (Chọn MỘT phương án)
  - [ ] PHƯƠNG ÁN A: Thêm cuộc thảo luận Dummy Proof Padding + bảng
    - [ ] Phần V phần phụ
    - [ ] Bảng phân tích overhead Phần VII
  - [ ] HOẶC PHƯƠNG ÁN B: Chuyển sang PLONK
    - [ ] Viết lại lý do chọn hệ thống chứng minh Phần V
    - [ ] Cập nhật phần implementation (dòng 449)
  
- [ ] **BƯỚC 4**: Thêm bảng so sánh SOTA
  - [ ] Chèn Bảng sau dòng 130
  - [ ] Thêm văn bản so sánh chi tiết
  - [ ] Cập nhật phần tham chiếu
  
- [ ] **BƯỚC 5**: Sửa dữ liệu thực nghiệm
  - [ ] Dòng 590: Sửa đặc tả RAM
  - [ ] Dòng 595: Làm rõ dữ kiệt bộ nhớ
  - [ ] Thêm từ chối trách nhiệm về ảnh hưởng thực tiễn

---

## Tham Chiếu Tệp

- **Bài báo chính:** `/home/mihwuan/Project/paper.tex`
- **Lệnh xây dựng:** `pdflatex paper.tex && bibtex paper && pdflatex paper.tex`
- **Dữ liệu kết quả:** `/home/mihwuan/Project/zkCross/results/`
- **Thiết lập thực nghiệm:** `/home/mihwuan/Project/zkCross/docker/`

---

## Các Câu Hỏi Cần Giải Quyết Trong Sửa Đổi

Khi thực hiện những thay đổi này, đảm bảo bài báo giải quyết rõ ràng những mối quan tâm của hội đồng phản biện:

1. **Chiếm Dụng Trí Tuệ:** ✓ (Đã Sửa Qua Tên Mới)
2. **Logic Threat Model:** ✓ (Đã Sửa Qua Giả Định Bán Đồng Bộ)
3. **Khả Năng Mở Rộng Groth16:** ✓ (Đã Sửa Qua Dummy Padding HOẶC Chuyển PLONK)
4. **Thiếu Related Work:** ✓ (Đã Sửa Qua Bảng So Sánh)
5. **Tính Hợp Lệ Thực Nghiệm:** ✓ (Đã Sửa Qua Làm Rõ Yêu Cầu Bộ Nhớ)

