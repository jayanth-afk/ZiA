import sys
import os

token = sys.argv[1] if len(sys.argv) > 1 else "no_token"
flag_file = "build/step2_flag.txt"

if not os.path.exists(flag_file):
    with open(flag_file, "w") as f:
        f.write("flag")
    print(f"temporary failure in step 2 with token: {token}", file=sys.stderr)
    sys.exit(1)

print(f"step2_success_with_{token}")
sys.exit(0)
