import re
import glob

def patch_rust_files():
    files = glob.glob('src/**/*.rs', recursive=True)
    for path in files:
        with open(path, 'r') as f:
            c = f.read()
        
        # Tìm và sửa các đoạn code lưu file trực tiếp gặp lỗi trait
        pattern = r'let mut ([a-zA-Z0-9_]+)_file = std::fs::File::create\((.*?)\)\?;\s*([a-zA-Z0-9_.]+)\.serialize_compressed\(&mut \1_file\)\?;'
        replacement = r'let mut \1_bytes = Vec::new(); \3.serialize_compressed(&mut \1_bytes).map_err(|e| color_eyre::eyre::eyre!("{:?}", e))?; std::fs::write(\2, \1_bytes)?;\n'
        
        c = re.sub(pattern, replacement, c)
        
        with open(path, 'w') as f:
            f.write(c)

patch_rust_files()
