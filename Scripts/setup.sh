#!/bin/bash
# JARVIS — First-time setup script
# Run once on a fresh machine to prepare the development environment.

set -euo pipefail

echo "=== JARVIS Setup ==="
echo ""

# 1. Check Swift version
echo "Checking Swift..."
if command -v swift &> /dev/null; then
    SWIFT_VERSION=$(swift --version 2>&1 | head -1)
    echo "  ✓ $SWIFT_VERSION"
else
    echo "  ✗ Swift not found. Install Xcode or Xcode Command Line Tools."
    exit 1
fi

# 2. Check macOS version
echo "Checking macOS..."
OS_VERSION=$(sw_vers -productVersion)
echo "  ✓ macOS $OS_VERSION"

# 3. Create runtime directories
echo "Creating directories..."
JARVIS_DIR="$HOME/.jarvis"
mkdir -p "$JARVIS_DIR/models"
mkdir -p "$JARVIS_DIR/data"
mkdir -p "$JARVIS_DIR/logs"
mkdir -p "$JARVIS_DIR/benchmarks"
echo "  ✓ Created $JARVIS_DIR/{models,data,logs,benchmarks}"

# 4. Create local directories in project
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
mkdir -p "$PROJECT_DIR/Models"
mkdir -p "$PROJECT_DIR/Data"
echo "  ✓ Created project data directories"

# 5. Resolve SPM dependencies
echo ""
echo "Resolving SPM dependencies..."
cd "$PROJECT_DIR"
swift package resolve
echo "  ✓ Dependencies resolved"

# 6. Build
echo ""
echo "Building JARVIS..."
swift build 2>&1
echo "  ✓ Build succeeded"

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Next steps:"
echo "  1. Run JARVIS:              swift run Jarvis"
echo "  2. Run tests:               swift test"
echo "  3. Run model benchmark:     python3 Scripts/benchmark.py"
echo "  4. Configure API keys:      (via JARVIS Settings UI)"
echo ""
