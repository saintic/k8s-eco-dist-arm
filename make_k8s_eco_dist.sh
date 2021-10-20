#!/bin/bash
#
# 说明：在 ARM64 架构上构建 Kubernetes 组件中默认没有 ARM 软件包的程序。
#
# 依赖： git wget unzip go(自动安装)
#

readonly CURRENT_DIR=$(cd `dirname $0`; pwd)
readonly DIST_DIR="${CURRENT_DIR}/dist"

# 下载WEB资源加速器
readonly HTTP_DOWNLOAD_PROXY=https://d.tcw.im/get/
# git克隆代理加速
readonly GIT_DOWNLOAD_PROXY=https://gitclone.com/
# go模块下载代理
readonly GO_MOD_PROXY=https://goproxy.cn,direct
# go二进制包下载地址
readonly GOLANG_BINARY_URL=https://golang.org/dl/go1.17.2.linux-arm64.tar.gz
# CFSSL GitHub 仓库地址，如果使用了克隆代理加速，注意是否携带协议头http
readonly CFSSL_GITREPO=github.com/cloudflare/cfssl/
# Containerd GiHub 仓库地址
readonly CONTAINERD_GITREPO=github.com/containerd/containerd
# Containerd依赖核心 runc 的 GitHub 仓库地址
readonly RUNC_GITREPO=github.com/opencontainers/runc

# 自动安装Golang环境
readonly AUTO_INSTALL_GOLANG=${auto_install_golang:-false}
# CFSSL版本号（分支）
readonly CFSSL_VERSION=${cfssl_version:-v1.4.1}
# Containerd版本号（分支）
readonly CONTAINERD_VERSION=${containerd_version:-v1.5.5}
# Runc版本号（分支）
readonly RUNC_VERSION=${runc_version:-v1.0.1}

set -o nounset

_checkExitRetcode() {
    local code=$?
    local tip="$*"
    if [ "${code}" != "0" ]; then
        echo "Command sending error code $code in $(pwd): $tip"
        exit 128
    fi
}

_gitclone() {
    local repo=$1
    local br=$2
    local dir=$3
    if [ -z "$repo" ]; then
        echo "require repo param"
        exit 1
    fi
    if [ -n "$dir" ] && [ -d $dir ]; then
        return
    fi
    git clone --recursive --branch "$br" "${GIT_DOWNLOAD_PROXY}${repo}" "${dir}"
    return $?
}

_os_type() {
    if grep -Eqii "CentOS" /etc/issue || grep -Eq "CentOS" /etc/*-release; then
        DISTRO='CentOS'
    elif grep -Eqi "Red Hat Enterprise Linux Server" /etc/issue || grep -Eq "Red Hat Enterprise Linux Server" /etc/*-release; then
        DISTRO='RHEL'
    elif grep -Eqi "Aliyun" /etc/issue || grep -Eq "Aliyun" /etc/*-release; then
        DISTRO='Aliyun'
    elif grep -Eq "Kylin" /etc/*-release; then
        DISTRO='Kylin'
    elif grep -Eqi "Fedora" /etc/issue || grep -Eq "Fedora" /etc/*-release; then
        DISTRO='Fedora'
    elif grep -Eqi "Debian" /etc/issue || grep -Eq "Debian" /etc/*-release; then
        DISTRO='Debian'
    elif grep -Eqi "Ubuntu" /etc/issue || grep -Eq "Ubuntu" /etc/*-release; then
        DISTRO='Ubuntu'
    elif grep -Eqi "Raspbian" /etc/issue || grep -Eq "Raspbian" /etc/*-release; then
        DISTRO='Raspbian'
    else
        DISTRO='unknow'
    fi
    echo $DISTRO;
}

_install_golang() {
    echo "Installing golang environment"

    local tarpkg=golang.tar.gz
    wget -c -O "$tarpkg" "${HTTP_DOWNLOAD_PROXY}${GOLANG_BINARY_URL}"
    _checkExitRetcode "download golang binary package error"

    [ -d /usr/local/go ] && echo "The \"go\" directory exists" && exit 2
    tar zxf $tarpkg -C /usr/local/
    _checkExitRetcode "unpack golang binary package error"

    ln -sf /usr/local/go/bin/go /usr/bin/go
}

_precheck() {
    local arch=$(uname -m)
    if [ "$arch" != "aarch64" ] && [ "$arch" != "arm64" ]; then
        echo "Only run in ARM64 system"
        exit 127
    fi
    git version > /dev/null 2>&1
    _checkExitRetcode "not found git"
    unzip --help > /dev/null 2>&1
    _checkExitRetcode "not found unzip"
    gv=$(go env GOVERSION | tr -d 'go' | awk -F '.' '{print $2}')
    _checkExitRetcode "not found go"
    if [ $gv -lt 15 ]; then
        echo "require go1.15"
        exit 1
    elif [ -z $gv ]; then
        if [ "$AUTO_INSTALL_GOLANG" = "true" ]; then
            _install_golang
        else
            echo "Do not install go, exit"
            exit 1
        fi
    fi
}

pkg_download_all() {
    _gitclone $CFSSL_GITREPO "$CFSSL_VERSION" cfssl-src
    _checkExitRetcode "git clone cfssl error"

    _gitclone $CONTAINERD_GITREPO "$CONTAINERD_VERSION" containerd-src
    _checkExitRetcode "git clone containerd error"

    _gitclone $RUNC_GITREPO "$RUNC_VERSION" runc-src
    _checkExitRetcode "git clone runc error"
}

make_cfssl() {
    cd cfssl-src || exit
    # require go.14+
    # Cross Compilation
    # make bin/rice
    # CGO_ENABLED=0 GOOS=linux GOARCH=arm64 make
    GO111MODULE=on GOPROXY=$GO_MOD_PROXY make
    _checkExitRetcode "build cfssl error"
    cd bin || exit
    tar zcvf "${DIST_DIR}/cfssl/cfssl-${CFSSL_VERSION}.tar.gz" cfssl cfssljson cfssl-certinfo
    _checkExitRetcode "pack cfssl error"
    cd ../../ || exit
}

make_containerd() {
    case "$(_os_type)" in
        RHEL|CentOS|Fedora|Aliyun|Kylin):
            yum install -y btrfs-progs-devel libseccomp-devel
            _checkExitRetcode "yum: failed to install dependencies"
        ;;
        Ubuntu|Debian)
            # Debian(before Buster)/Ubuntu(before 19.10): apt-get install btrfs-tools
            apt-get install -y btrfs-progs libbtrfs-dev libseccomp-dev
            _checkExitRetcode "apt: failed to install dependencies"
        ;;
        *)
            echo "unsupport os"
            exit 1
        ;;
    esac

    unzip -o protoc.zip -d /usr/local/
    _checkExitRetcode "protoc unzip error"

    local cbd="containerd-bin"
    [ -d $cbd ] && rm -rf $cbd
    mkdir $cbd

    # runc require go1.15+ and libseccomp-devel
    cd runc-src || exit
    GO111MODULE=on GOPROXY=$GO_MOD_PROXY make
    _checkExitRetcode "build runc error"
    cp -f runc ../${cbd}/

    # container require go1.14+ and btrfs-progs-devel
    cd ../containerd-src || exit
    GO111MODULE=on GOPROXY=$GO_MOD_PROXY make
    _checkExitRetcode "build containerd error"
    cp -f bin/* ../${cbd}

    cd "../${cbd}" || exit
    tar zcvf "${DIST_DIR}/containerd/containerd-${CONTAINERD_VERSION}.tar.gz" "."
    _checkExitRetcode "pack containerd error"

    cd .. || exit
}

make_pkg() {
    make_cfssl
    make_containerd
}

main() {
    local TMPDIR="/tmp/_build_k8s_eco_pacakge"
    mkdir -p "${TMPDIR}" "${DIST_DIR}"/{cfssl,containerd}

    cd "$TMPDIR" || exit
    _precheck

    pkg_download_all
    make_pkg

    cd "$CURRENT_DIR" || exit
    echo "Pack all successfully."
}

Clean() {
    echo "The program was terminated, will exit!"
    exit 1
}

trap 'Clean; exit' SIGINT SIGTERM

main "$@"
