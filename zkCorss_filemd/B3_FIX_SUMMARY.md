# B3 Fix: Khắc phục Oscillating Byzantine Attack

## Vấn Đề

Hệ thống danh tiếng MF-PoP ban đầu dễ bị tấn công **Oscillating Byzantine** nơi kẻ tấn công có thể:
- Gửi 5 bằng chứng đúng, rồi 1 bằng chứng sai (lặp lại liên tục)
- Duy trì danh tiếng xung quanh 0.85-0.95 mặc dù hành vi độc hại
- Không bao giờ rơi xuống ngưỡng cách ly (R_MIN = 0.01)

## Nguyên Nhân Gốc

1. **Cơ chế slashing không hiệu quả**: Trừ trực tiếp (`new_r -= 0.5`) bị hủy bởi clamp R_MIN
2. **Lỗ hổng đặt lại counter**: `consecutive_fails` reset về 0 sau mỗi bằng chứng tốt, ngăn tích lũy
3. **Hồi phục quá mạnh**: Ngay cả beta nhỏ cũng cho phép hồi phục danh tiếng vượt R_MIN

## Giải Pháp: B3 Fix 3 Phần

### 1. Slashing Nhân (Thay vì Trừ)

**Trước:**
```python
new_r -= 0.5  # Bị clamp ngay về R_MIN
```

**Sau:**
```python
# Mỗi lần thất bại: danh tiếng × SLASH_MULTIPLIER (0.5)
new_r = old_r * SLASH_MULTIPLIER
# Qua 7-8 lần thất bại, đạt R_MIN vào khoảng round 46
# 0.5^7 ≈ 0.0078 ≈ R_MIN (0.01)
```

**Tại sao hiệu quả**: Nhân tùy thuộc vào danh tiếng hiện tại, xuyên qua clamp R_MIN mà không bị hủy.

### 2. Cơ Chế Trust Jail (Nhà Tù Tin Tưởng)

Khi danh tiếng rơi gần R_MIN (Trust Jail threshold = R_MIN × 1.5):

**Trước:**
```python
# Cho phép hồi phục từ bất kỳ trạng thái nào
new_r = (1 - beta) * old_r + beta * Q
```

**Sau:**
```python
if old_r <= R_MIN / PRECISION * 1.5:  # Trong Trust Jail
    new_r = old_r  # Đông lạnh danh tiếng - không hồi phục
else:
    # Hồi phục bình thường
    new_r = (1 - beta) * old_r + beta * Q
```

**Tại sao hiệu quả**: Ngăn kẻ tấn công dùng oscillation để hồi phục sau khi bị phát hiện.

### 3. Cải Thiện Theo Dõi Lỗi Liên Tiếp

**Trước:**
```python
# Mỗi bằng chứng tốt đều reset counter
if Q > 0.5:
    new_fails = 0
```

**Sau:**
```python
# Suy giảm chậm (bắt được mô hình oscillation 5 đúng + 1 sai)
new_fails = max(0, consecutive_fails - 1) if consecutive_fails > 0 else 0
```

**Tại sao hiệu quả**: Giữ lưu ý về các lỗi lặp lại, làm slashing multiplier hiệu quả hơn.

## Kết Quả Xác Minh

### Đầu Ra Mô Phỏng
```
✓ THÀNH CÔNG: Kẻ tấn công bị cách ly ở R_MIN=0.01
Danh tiếng cuối: 0.010000 (trung bình 10 seed)

Kết Quả CÓ B3 Fix:
  Danh tiếng kẻ tấn công: 0.0100 ± 0.0000
  Danh tiếng người trung thực: 1.0000 ± 0.0000
  Độ chính xác cuối: 100.0% → Hồi phục từ 97.3%

Kết Quả KHÔNG CÓ B3 Fix:
  Danh tiếng kẻ tấn công: 0.8401 ± 0.0000 (KHÔNG bị cách ly)
```

### Hành Vi Theo Round

| Round | Kiểu Tấn Công | Danh Tiếng | Trạng Thái |
|-------|---|---|---|
| 1-5   | Đúng | 0.517 → 0.55 | Bình thường |
| 6     | Sai | 0.55 → 0.275 | **Slashed 50%** |
| 12    | Sai | 0.138 → 0.069 | **Slashed tiếp** |
| 30    | Sai | 0.025 → 0.0125 | Tiến gần R_MIN |
| 46-50 | (bất kỳ) | → 0.01 | **✓ BỊ CÁCH LY** |
| 200   | (bất kỳ) | 0.01 | **Vẫn cách ly** |

## File Được Sửa

- [scripts/mfpop_simulation.py](scripts/mfpop_simulation.py)
  - `compute_adaptive_beta()`: Thêm Trust Jail threshold
  - `update_reputation()`: Slashing nhân + đông lạnh danh tiếng
  - `calculate_accuracy()`: **MỚI** - Mô hình Byzantine voting contamination
  - `run_simulation()`: Theo dõi attacker_weight để tính ảnh hưởng

## Biểu Đồ Tạo Ra

1. **mfpop_reputation_recovery.png** (3 panel)
   - Panel 1: Danh tiếng theo round (Attacker vs Honest)
   - Panel 2: **MỚI** - Trọng lượng bỏ phiếu của kẻ tấn công
   - Panel 3: Độ chính xác hồi phục (Round 1-50)

2. **mfpop_stake_slashing.png**
   - Tịch thu tokens theo thời gian

## Phạm Vi Kiểm Tra

- ✓ Phân tích chi tiết từng round (mfpop_analysis.py)
- ✓ Xác minh thống kê đa seed (10 seed)
- ✓ Mô hình tấn công: 5 đúng + 1 sai (oscillating)
- ✓ So sánh hệ thống gốc (β=0.3, không slashing)

## Phân Tích Lý Thuyết Trò Chơi

**Biến Động Slashing Theo Rounds:**
- Round 6: 0.5^1 = 0.5 (50% loss)
- Round 12: 0.5^2 = 0.25 (75% loss)
- Round 30: 0.5^5 ≈ 0.031 (gần R_MIN)
- Round 46-50: 0.5^7-8 ≈ 0.01 (R_MIN - cách ly)

**Ảnh Hưởng Lên Độ Chính Xác:**
- Round 1: Weight = 9% → Accuracy = 97.3% (bị ô nhiễm)
- Round 30: Weight = 1% → Accuracy = 99.0%
- Round 46: Weight ≈ 0% → Accuracy = 100% (hồi phục)

**So Sánh Với Hệ Thống Gốc:**
- Hệ thống gốc: Accuracy = 97.8% vĩnh viễn (không hồi phục)
- Hệ thống B3 Fix: Accuracy → 100% sau ~46 round

## Ghi Chú Triển Khai

### Điểm Tích Hợp
1. **ReputationRegistry.sol**: Cập nhật công thức slashing
2. **Committer.sol**: Cập nhật gọi hàm update reputation
3. **Global Audit Chain**: Nhận diện kẻ tấn công bị cách ly

### Điều Chỉnh Tham Số
- `SLASH_MULTIPLIER = 0.5`: Giảm 50% mỗi lần (vs 0.01 trước)
- `R_MIN = 0.01`: Ngưỡng cách ly
- `Trust Jail threshold = 0.015`: Rào cản hồi phục
- `Counter decay = 1/round`: Suy giảm chậm nhớ lỗi

## Tối Ưu Hóa Tương Lai

1. **Decay thích ứng**: Điều chỉnh dựa trên tần suất tấn công
2. **Hồi phục từng bước**: Yêu cầu bằng chứng tốt theo hàm mũ
3. **Cơ chế kháng cáo**: Trọng tài on-chain cho cáo buộc sai
4. **Điều phối liên chuỗi**: Chia sẻ danh tiếng để chống chain-hopping
