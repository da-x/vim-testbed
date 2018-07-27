#!/bin/sh

set -e
set -x

bail() {
  echo "$@" >&2
  exit 1
}

init_vars() {
  FLAVOR=
  TAG=
  NAME=
  PYTHON2=
  PYTHON3=
  RUBY=0
  LUA=0
  CONFIGURE_OPTIONS=
  PREBUILD_SCRIPT=
}

prepare_build() {
  [ -z $TAG ] && bail "-tag is required"

  # Parse TAG into repo and tag.
  IFS=: read -r -- repo tag <<EOF
$TAG
EOF
  if [ -z "$tag" ]; then
    tag="$repo"
    repo=
  elif [ "$repo" = vim ]; then
    repo="vim/vim"
  elif [ "$repo" = neovim ]; then
    repo="neovim/neovim"
    [ -z "$FLAVOR" ] && FLAVOR=neovim
  elif [ "${repo#*/}" = "$repo" ]; then
    bail "Unrecognized repo ($repo) from tag: $TAG"
  elif [ "${repo#*/neovim}" != "$repo" ]; then
    FLAVOR=neovim
  fi
  if [ -z "$FLAVOR" ]; then
    FLAVOR=vim
  fi
  if [ -z "$repo" ]; then
    if [ "$FLAVOR" = vim ]; then
      repo="vim/vim"
    else
      repo="neovim/neovim"
    fi
  fi
  [ -z $NAME ] && NAME="${FLAVOR}-${tag}"

  if [ "$FLAVOR" = vim ]; then
    VIM_NAME="${repo}/${tag}_py${PYTHON2}${PYTHON3}_rb${RUBY}_lua${LUA}"
  else
    VIM_NAME="${repo}/${tag}"
  fi
  INSTALL_PREFIX="/vim-build/$VIM_NAME"

  if [ "$FLAVOR" = vim ]; then
    CONFIG_ARGS="--prefix=$INSTALL_PREFIX --enable-multibyte --without-x --enable-gui=no --with-compiledby=vim-testbed --enable-pythoninterp=dynamic"
  fi
  set +x
  echo "TAG:$TAG"
  echo "repo:$repo"
  echo "tag:$tag"
  echo "FLAVOR:$FLAVOR"
  echo "NAME:$NAME"
  set -x

  dnf install -y python2-pip

  TRANS_ID=$(dnf history list | grep -E '^ +[0-9]+' | head -n 1 | awk -F" " '{print $1}')

  echo "DNF Transaction: ${TRANS_ID}"

  if [ -n "$PYTHON2" ]; then
    if [ "$FLAVOR" = vim ]; then
      CONFIG_ARGS="$CONFIG_ARGS --enable-pythoninterp=dynamic"
    else
      pip2 install neovim
    fi
  fi

  if [ -n "$PYTHON3" ]; then
    if [ "$FLAVOR" = vim ]; then
      CONFIG_ARGS="$CONFIG_ARGS --enable-python3interp=dynamic"
    else
      pip3 install neovim
    fi
  fi

  if [ $RUBY -eq 1 ]; then
    if [ "$FLAVOR" = vim ]; then
      CONFIG_ARGS="$CONFIG_ARGS --enable-rubyinterp"
    else
      gem install neovim
    fi
  fi

  if [ $LUA -eq 1 ]; then
    if [ "$FLAVOR" = vim ]; then
      CONFIG_ARGS="$CONFIG_ARGS --enable-luainterp"
    else
      echo 'NOTE: -lua is automatically used with Neovim 0.2.1+, and not supported before.'
    fi
  fi

  if [ "$FLAVOR" = vim ] && [ -n "$CONFIGURE_OPTIONS" ]; then
    CONFIG_ARGS="$CONFIG_ARGS $CONFIGURE_OPTIONS"
  fi

  cd /vim

  if [ -d "$INSTALL_PREFIX" ]; then
    echo "WARNING: $INSTALL_PREFIX exists already.  Overwriting."
  fi

  BUILD_DIR="${FLAVOR}-${repo}-${tag}"
  if [ ! -d "$BUILD_DIR" ]; then
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"
    # The git package adds about 200MB+ to the image.  So, no cloning.
    url="https://github.com/$repo/archive/${tag}.tar.gz"
    echo "Downloading $repo:$tag from $url"
    curl --retry 3 -SL "$url" | tar zx --strip-components=1
  else
    cd "$BUILD_DIR"
  fi

  dnf groupinstall -y "Development Tools" "Development Libraries"

# https://src.fedoraproject.org/rpms/vim/raw/f28/f/vim.spec

  dnf install -y \
      hunspell-devel \
      gcc gcc-c++ gettext ncurses-devel \
      perl-generators \
      libacl-devel gpm-devel autoconf file \
      libselinux-devel \
      ruby-devel ruby \
      lua-devel \
      glibc-devel \
      make \
      desktop-file-utils \

  if [ "$FLAVOR" = vim ]; then
    echo ?
  elif [ "$FLAVOR" = neovim ]; then
    # Some of them will be installed already, but it is a good reference for
    # what is required.
    # luajit is required with Neomvim 0.2.1+ (previously only during build).
    dnf install -y \
	  cmake fdupes \
	  gperf \
	  lua-devel \
	  lua-lpeg \
	  lua-mpack \
	  jemalloc-devel \
	  msgpack-devel \
	  libtermkey-devel \
	  libuv-devel \
	  libvterm-devel \
	  unibilium-devel \
	  jemalloc
  else
    bail "Unexpected FLAVOR: $FLAVOR (use vim or neovim)."
  fi
}

build() {
  if [ -n "$PREBUILD_SCRIPT" ]; then
    eval "$PREBUILD_SCRIPT"
  fi

  if [ "$FLAVOR" = vim ]; then
    # Apply build fix from v7.1.148.
    MAJOR="$(sed -n '/^MAJOR = / s~MAJOR = ~~p' Makefile)"
    if [ "$MAJOR" -lt 8 ]; then
      MINOR="$(sed -n '/^MINOR = / s~MINOR = ~~p' Makefile)"
      if [ "$MINOR" = "1" ] || [ "${MINOR#0}" != "$MINOR" ]; then
        sed -i 's~sys/time.h termio.h~sys/time.h sys/types.h termio.h~' src/configure.in src/auto/configure
      fi
    fi

    echo "Configuring with: $CONFIG_ARGS"
    # shellcheck disable=SC2086
    ./configure $CONFIG_ARGS || bail "Could not configure"
    make CFLAGS="-U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=2" -j4 || bail "Make failed"
    make install || bail "Install failed"

  elif [ "$FLAVOR" = neovim ]; then
    sed -i 's/mpack bit)/mpack bit32)/g' CMakeLists.txt 
    sed -i "s/require 'bit'/require 'bit32'/" src/nvim/ex_cmds.lua
    mkdir build
    cd build
    cmake -DCMAKE_BUILD_TYPE=RelWithDebInfo \
      -DCMAKE_INSTALL_PREFIX=$INSTALL_PREFIX \
      -DENABLE_JEMALLOC=OFF \
      -DPREFER_LUA=ON -DLUA_PRG=/usr/bin/lua \
         .. || bail "Make failed"

    versiondef_file=config/auto/versiondef.h
    if grep -qF '#define NVIM_VERSION_PRERELEASE "-dev"' $versiondef_file \
        && grep -qF '/* #undef NVIM_VERSION_MEDIUM */' $versiondef_file ; then

      head_info=$(curl --retry 3 -SL "https://api.github.com/repos/$repo/git/refs/heads/$tag")
      if [ -n "$head_info" ]; then
        head_sha=$(echo "$head_info" | grep '"sha":' | cut -f4 -d\" | cut -b -7)
        if [ -n "$head_sha" ]; then
          sed -i "s/#define NVIM_VERSION_PRERELEASE \"-dev\"/#define NVIM_VERSION_PRERELEASE \"-dev-$head_sha\"/" $versiondef_file
        fi
      fi
    fi
    make install || bail "Install failed"
    cd ..
  fi

  # Clean, but don't delete the source in case you want make a different build
  # with the same version.
  make distclean

  if [ "$FLAVOR" = vim ]; then
    VIM_BIN="$INSTALL_PREFIX/bin/vim"
  else
    VIM_BIN="$INSTALL_PREFIX/bin/nvim"
  fi
  link_target="/vim-build/bin/$NAME"
  if [ -e "$link_target" ]; then
    echo "WARNING: link target for $NAME exists already.  Overwriting."
  fi
  ln -sfn "$VIM_BIN" "$link_target"
  "$link_target" --version
}

init_vars
clean=
while [ $# -gt 0 ]; do
  case $1 in
    -flavor)
      if [ "$2" != vim ] && [ "$2" != neovim ]; then
        bail "Invalid value for -flavor: $2: only vim or neovim are recognized."
      fi
      FLAVOR="$2"
      shift
      ;;
    -name)
      NAME="$2"
      shift
      ;;
    -tag)
      TAG="$2"
      shift
      ;;
    -py|-py2)
      PYTHON2=2
      ;;
    -py3)
      PYTHON3=3
      ;;
    -ruby)
      RUBY=1
      ;;
    -lua)
      LUA=1
      ;;
    -prepare_build)
      # Not documented, meant to ease hacking on this script, by avoiding
      # downloads over and over again.
      prepare_build
      [ -z "$clean" ] && clean=0
      ;;
    -skip_clean)
      clean=0
      ;;
    -prebuild_script)
      PREBUILD_SCRIPT="$2"
      shift
      ;;
    -build)
      # So here I am thinking that using Alpine was going to give the biggest
      # savings in image size.  Alpine starts at about 5MB.  Built this image,
      # and it's about 8MB.  Looking good.  Install two versions of vanilla
      # vim, 300MB wtf!!!  Each run of this script without cleaning up created
      # a layer with all of the build dependencies.  So now, this script
      # expects a -build flag to signal the start of a build.  This way,
      # installing all Vim versions becomes one layer.
      # Side note: tried docker-squash and it didn't seem to do anything.
      echo "=== building: NAME=$NAME, TAG=$TAG, PYTHON=${PYTHON2}${PYTHON3}, RUBY=$RUBY, LUA=$LUA, FLAVOR=$FLAVOR ==="
      prepare_build
      build
      init_vars
      [ -z "$clean" ] && clean=1
      ;;
    *)
      CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS $1"
      ;;
  esac

  shift
done

if [ "$clean" = 0 ]; then
  echo "NOTE: skipping cleanup."
else
  echo "Pruning packages and dirs.."
  rm -rf /vim/*
  #
  # Doesn't work because of missing packages :(
  # dnf history rollback ${TRANS_ID}
fi
