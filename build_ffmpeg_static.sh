#!/bin/bash

# Script to install dependencies and compile FFmpeg statically
# Prerequisites: Ubuntu with sudo, internet connection
# Date: March 2025

set -e  # Stop script on error

# Variables
INSTALL_DIR="/usr/local"
SRC_DIR="$HOME/ffmpeg_build"
FFMPEG_VERSION="git"  # Use the latest version from Git

# Create a working directory
mkdir -p "$SRC_DIR"
cd "$SRC_DIR"

# Update system and install basic tools
echo "Updating system and installing basic tools..."
sudo apt update
sudo apt install -y build-essential git cmake yasm nasm pkg-config unzip wget

# Install NVIDIA drivers (if not already done, for NVENC)
if ! command -v nvidia-smi &> /dev/null; then
    echo "Installing NVIDIA drivers..."
    sudo apt install -y nvidia-driver-535 nvidia-utils-535
fi

# Function to clone or update a git repository
clone_or_update() {
    local repo_url="$1"
    local dir_name="$2"
    
    if [ -d "$dir_name" ]; then
        echo "Directory $dir_name already exists, updating..."
        cd "$dir_name"
        git pull
        cd ..
    else
        echo "Cloning $repo_url to $dir_name..."
        git clone "$repo_url" "$dir_name"
    fi
}

# Function to compile and install a static dependency
compile_static() {
    local name="$1"
    local url="$2"
    local configure_cmd="$3"
    echo "Compiling $name..."
    
    clone_or_update "$url" "$name"
    cd "$name"
    $configure_cmd
    make -j$(nproc)
    sudo make install
    cd ..
}

# Install zlib, bzip2, lzma statically (often already present as .a)
echo "Installing compression libraries..."
sudo apt install -y zlib1g-dev libbz2-dev liblzma-dev

# Compile libvpx (VP8/VP9)
compile_static "libvpx" "https://chromium.googlesource.com/webm/libvpx" \
    "./configure --enable-static --disable-shared --enable-vp8 --enable-vp9"

# Compile SVT-AV1
echo "Compiling SVT-AV1..."
clone_or_update "https://gitlab.com/AOMediaCodec/SVT-AV1.git" "SVT-AV1"
cd SVT-AV1/Build
cmake .. -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR"
make -j$(nproc)
sudo make install
cd ../..

# Compile x264
compile_static "x264" "https://code.videolan.org/videolan/x264.git" \
    "./configure --enable-static --disable-shared --disable-opencl --prefix=$INSTALL_DIR"

# Compile x265 with position independent code
echo "Compiling x265..."
clone_or_update "https://bitbucket.org/multicoreware/x265_git.git" "x265_git"
cd x265_git/source
cmake -G "Unix Makefiles" -DENABLE_SHARED=OFF -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" -DCMAKE_POSITION_INDEPENDENT_CODE=ON
make -j$(nproc)
sudo make install
# Create symbolic link if necessary (some systems expect libx265.a in lib64)
if [ -f "$INSTALL_DIR/lib64/libx265.a" ] && [ ! -f "$INSTALL_DIR/lib/libx265.a" ]; then
    sudo mkdir -p "$INSTALL_DIR/lib"
    sudo ln -sf "$INSTALL_DIR/lib64/libx265.a" "$INSTALL_DIR/lib/libx265.a"
fi
# Ensure the header is also properly linked
if [ -f "$INSTALL_DIR/include/x265.h" ]; then
    echo "x265 header found in the expected location"
else
    # Try to find x265.h and link it to the expected location
    x265_header=$(find "$INSTALL_DIR" -name "x265.h" | head -n 1)
    if [ -n "$x265_header" ]; then
        echo "Found x265 header at $x265_header, creating symlink"
        sudo mkdir -p "$INSTALL_DIR/include"
        sudo ln -sf "$x265_header" "$INSTALL_DIR/include/x265.h"
    fi
fi
cd ../..

# Compile libmp3lame
echo "Compiling LAME (MP3)..."
if [ ! -d "lame-3.100" ]; then
    wget -nc https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz
    tar -xzf lame-3.100.tar.gz
fi
cd lame-3.100
./configure --enable-static --disable-shared --prefix="$INSTALL_DIR"
make -j$(nproc)
sudo make install
cd ..

# Compile libopus
echo "Compiling Opus..."
if [ ! -d "opus-1.5.2" ]; then
    wget -nc https://downloads.xiph.org/releases/opus/opus-1.5.2.tar.gz
    tar -xzf opus-1.5.2.tar.gz
fi
cd opus-1.5.2
./configure --enable-static --disable-shared --prefix="$INSTALL_DIR"
make -j$(nproc)
sudo make install
cd ..

# Install NVENC headers (ffnvcodec)
echo "Installing NVENC headers (ffnvcodec)..."
clone_or_update "https://git.videolan.org/git/ffmpeg/nv-codec-headers.git" "nv-codec-headers"
cd nv-codec-headers
make
sudo make install
cd ..

# Update paths for pkg-config and ld
echo "Updating paths..."
sudo ldconfig
export PKG_CONFIG_PATH="$INSTALL_DIR/lib/pkgconfig:$INSTALL_DIR/lib64/pkgconfig:$PKG_CONFIG_PATH"

# Create a custom x265.pc file with correct paths
echo "Creating custom x265.pc file..."
if [ -f "$INSTALL_DIR/lib/libx265.a" ] || [ -f "$INSTALL_DIR/lib64/libx265.a" ]; then
    sudo mkdir -p "$INSTALL_DIR/lib/pkgconfig"
    sudo tee "$INSTALL_DIR/lib/pkgconfig/x265.pc" > /dev/null << EOF
prefix=$INSTALL_DIR
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: x265
Description: H.265/HEVC video encoder
Version: 4.1
Libs: -L\${libdir} -lx265
Libs.private: -lstdc++ -lm -ldl
Cflags: -I\${includedir}
EOF
    echo "Created custom x265.pc file"
fi

# Compile FFmpeg with explicit x265 paths
echo "Compiling FFmpeg..."
if [ "$FFMPEG_VERSION" = "git" ]; then
    clone_or_update "https://git.ffmpeg.org/ffmpeg.git" "ffmpeg"
else
    if [ ! -d "ffmpeg" ]; then
        wget -nc "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.bz2"
        tar -xjf "ffmpeg-$FFMPEG_VERSION.tar.bz2"
        mv "ffmpeg-$FFMPEG_VERSION" ffmpeg
    fi
fi

# Find x265 library path
X265_LIB_PATH=""
if [ -f "$INSTALL_DIR/lib/libx265.a" ]; then
    X265_LIB_PATH="$INSTALL_DIR/lib"
elif [ -f "$INSTALL_DIR/lib64/libx265.a" ]; then
    X265_LIB_PATH="$INSTALL_DIR/lib64"
fi

# Find x265 header path
X265_INCLUDE_PATH=""
if [ -f "$INSTALL_DIR/include/x265.h" ]; then
    X265_INCLUDE_PATH="$INSTALL_DIR/include"
else
    x265_header=$(find "$INSTALL_DIR" -name "x265.h" | head -n 1)
    if [ -n "$x265_header" ]; then
        X265_INCLUDE_PATH=$(dirname "$x265_header")
    fi
fi

echo "X265 Library path: $X265_LIB_PATH"
echo "X265 Include path: $X265_INCLUDE_PATH"

# Build FFmpeg with or without x265 based on availability
cd ffmpeg
if [ -n "$X265_LIB_PATH" ] && [ -n "$X265_INCLUDE_PATH" ]; then
    echo "Configuring FFmpeg with x265 support..."
    ./configure \
      --pkg-config-flags=--static \
      --disable-ffplay \
      --enable-libvpx \
      --enable-libsvtav1 \
      --enable-libx264 \
      --enable-libx265 \
      --enable-libmp3lame \
      --enable-libopus \
      --enable-runtime-cpudetect \
      --enable-gpl \
      --enable-version3 \
      --enable-static \
      --disable-shared \
      --enable-nonfree \
      --enable-nvenc \
      --extra-cflags="-I$INSTALL_DIR/include -I$X265_INCLUDE_PATH" \
      --extra-ldflags="-L$INSTALL_DIR/lib -L$X265_LIB_PATH -static -static-libgcc -static-libstdc++" \
      --extra-libs="-lx265 -lstdc++ -lm -ldl" \
      --disable-xlib \
      --disable-libxcb
else
    echo "WARNING: x265 libraries or headers not found, building without x265 support"
    ./configure \
      --pkg-config-flags=--static \
      --disable-ffplay \
      --enable-libvpx \
      --enable-libsvtav1 \
      --enable-libx264 \
      --enable-libmp3lame \
      --enable-libopus \
      --enable-runtime-cpudetect \
      --enable-gpl \
      --enable-version3 \
      --enable-static \
      --disable-shared \
      --enable-nonfree \
      --enable-nvenc \
      --extra-cflags="-I$INSTALL_DIR/include" \
      --extra-ldflags="-L$INSTALL_DIR/lib -static -static-libgcc -static-libstdc++" \
      --disable-xlib \
      --disable-libxcb
fi

make -j$(nproc)
sudo make install

# Check if the binary is static
echo "Verifying binary..."
ldd ./ffmpeg || echo "The binary is static if 'not a dynamic executable' appears above."

# Reduce binary size
echo "Optimizing binary..."
strip ./ffmpeg
ls -lh ./ffmpeg

# Final test
echo "Testing FFmpeg..."
./ffmpeg -version
./ffmpeg -encoders | grep nvenc || echo "NVENC not found (NVIDIA driver required at runtime)."
./ffmpeg -encoders | grep x265 && echo "x265 support confirmed!" || echo "WARNING: x265 encoder not found in the output"

echo "Compilation complete! Binary is at $(pwd)/ffmpeg"
echo "Copy ./ffmpeg to another machine to test its portability."