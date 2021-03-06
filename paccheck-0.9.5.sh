#!/bin/bash
# Script Name: paccheck
# Version: 0.9.5
# Actual developper: Bernard Baeyens (berbae)
# Original creator: IgnorantGuru http://igurublog.wordpress.com
#
# License: GNU GENERAL PUBLIC LICENSE Version 3 http://www.gnu.org/licenses/gpl-3.0.txt
#
# Compares pacman sync databases and package desc files to different mirrors
# Verifies size of packages in pacman cache
# Optionally compares packages in pacman cache to selected mirror(s)
#
# Desired mirrors from official Mirror list have to be saved in /etc/paccheck/mirrorlist
#
# Only official currently active mirrors are tested
#
# For best results use more than one tier 1 mirrors
# and/or tier 2 mirrors which synchronize from different tier 1 mirrors
#
# Useful links:
#   http://www.archlinux.org/mirrors/
#   http://www.archlinux.org/mirrors/status/
#   https://www.archlinux.de/?page=MirrorStatus
#
defmir=(
    'http://mirror.aarnet.edu.au/pub/archlinux/$repo/os/$arch'
    'ftp://ftp5.gwdg.de/pub/linux/archlinux/$repo/os/$arch'
    'http://ftp.tku.edu.tw/Linux/ArchLinux/$repo/os/$arch'
)

tmp="/tmp/paccheck.tmp"
mirrorlist="/etc/paccheck/mirrorlist"

# Uncomment to hard code $arch
#arch="x86_64"

##############################################################################

help()
{
    cat << EOF
paccheck version 0.9.5
Compares Arch Linux pacman sync databases and package desc files to multiple mirrors
Verifies package size
Optionally compares packages in pacman cache to selected mirror(s)

The script is intended to help to detect compromised mirrors

Usage: paccheck [OPTIONS]
OPTIONS:
--install PKG [...] Download packages (without sync) and check ONLY those
		    packages, then offer to install
--compare 'MIRROR'  Fully download and compare all non-expired packages in
		    pacman's pkg cache to MIRROR.  Can alternatively be
		    listed in $mirrorlist as "compare=MIRROR".
		    MIRROR can also be local dir with packages in MIRROR/pkg/
--targets           Limit check and download to current update targets only
--verbose           Show debugging output
--keep              Don't remove temporary files in $tmp
--alt-size          Use alternate slower test of package sizes (useful due
		    to stat bug with btrfs which gives inaccurate results)
--skip-size         Skip test of package sizes
--no-sync           No pacman update - mainly for use in scripts. paccheck
		    requires an updated pacman sync and package cache.
		    Before running "paccheck --no-sync" be sure to run:
			sudo pacman -Sy
			sudo pacman -w --noconfirm -Su

Full System Update Procedure:
    1) Run paccheck as not root user 
       pacman will be synced and needed packages downloaded
    2) Examine report
    3) If no package MISMATCH then run "sudo pacman -Su" to update your system

Desired mirrors have to be configured in $mirrorlist

NOTE: paccheck only tests these official repositories (if configured):
      core extra community community-staging community-testing
      gnome-unstable kde-unstable multilib multilib-testing staging testing

      paccheck only tests official currently active mirrors

Exit Status:
    3  Package MISMATCH, download failures, or other errors
    2  Packages missing from some mirrors
    1  Out of sync mirrors (DATABASE CONTENT MISMATCH) or other warnings
    0  All OK

EOF
    exit
}

# Parse options
while [[ "$1" != "" ]];
do
    if [[ "${1:0:1}" == "-" ]]; then
        case "$1" in
            --help | -help | -h )
                help
                exit
                ;;
            --keep )
                keep=1;;
            --diag )
                # unadvertised - repeat the analysis, no download
                # run paccheck with --keep before using --diag
                diag=1;;
            --brief )
                # unadvertised - download a few compare files, not all -
                # for testing purposes only! 
                brief=1;;
            --sample )
                sample=1;;
            --verbose )
                verbose=1;;
            --skip-size )
                skipsize=1;;
            --alt-size )
                altsize=1;;
            --no-sync )
                nosync=1;;
            --targets )
                targets=1;;
            * )
                if [[ "${1:0:9}" == "--compare" ]]; then
                    a="${1:9}"
                    a="${a#=}"
                    if [[ "$a" == "" ]]; then
                        if [[ "${2:0:1}" == "-" ]] || [[ "$2" == "" ]]; then
                            echo "ERROR: Option --compare requires an argument"
                            exit 3
                        fi
                        a="$2"
                        shift
                    fi
		    if [[ "${a:0:1}" != "/" ]]; then
			a="${a%%\$*}"
			a="${a%/}"
			a="$a/\$repo/os/\$arch"
		    fi
		    cmpmir+=("$a")
                elif [[ "${1:0:9}" == "--install" ]]; then
                    a="${1:9}"
                    a="${a#=}"
                    if [[ "$a" == "" ]]; then
                        if [[ "${2:0:1}" == "-" ]] || [[ "$2" == "" ]]; then
                            echo "ERROR: Option --install requires an argument"
                            exit 3
                        fi
                    else
                        pkglist+=" $a"
                    fi
                    while [[ "$2" != "" ]] && [[ "${2:0:1}" != "-" ]]; do
                        pkglist+=" $2"
                        shift
                    done
                else
                    echo "ERROR: Unknown option $1"
                    exit 3
                fi
                ;;
        esac
    else
        echo "ERROR: Unrecognized argument $1"
        exit 3
    fi
    shift
done

if [[ "$(whoami)" == "root" ]]; then
    echo "do not run as root"
    exit 3
fi

if [[ "$arch" == "" ]]; then
    arch=$(grep "^CARCH=" /etc/makepkg.conf | cut -d\" -f2)
fi
if [[ "$arch" != "x86_64" ]] && [[ "$arch" !=  "i686" ]]; then
    echo "ERROR: could not determine \$arch"
    exit 3
fi

if [[ -e "$mirrorlist" ]]; then
    echo
    echo "Reading mirrors from $mirrorlist..."
    while read l; do
	# remove whitespace and comments
	l="${l//[[:blank:]]/}"
	l="${l%%#*}"
	ll="${l:0:7}"
	compare=0
	if [[ "${ll,,}" == "compare" ]]; then
	    l="${l:7}"
	    compare=1
	fi
	l="${l#*=}"
	if [[ "$l" != "" ]]; then
	    if [[ "${l:0:1}" != "/" ]]; then
		l="${l%%\$*}"
		l="${l%/}"
		l="$l/\$repo/os/\$arch"
	    fi
	    if ((compare == 1)); then
		cmpmir+=("$l")
	    else
		mir+=("$l")
	    fi
	fi
    done < "$mirrorlist"
fi
if [[ "${!mir[@]}" == "" ]]; then
    mir+=("${defmir[@]}")
fi

# Read pacman defaults
dbpath=$(grep "^DBPath.*=" /etc/pacman.conf | tr -d [[:blank:]] | cut -d= -f2)
cachedir=$(grep "^CacheDir.*=" /etc/pacman.conf | tr -d [[:blank:]] | cut -d= -f2)
dbpath="${dbpath%/}"
cachedir="${cachedir%/}"
if [[ "$dbpath" == "" ]]; then
    dbpath="/var/lib/pacman"
fi
if [[ "$cachedir" == "" ]]; then
    cachedir="/var/cache/pacman/pkg"
fi

# Run pacman
echo
if ((diag != 1)) && ((nosync != 1)) && [[ "$pkglist" == "" ]]; then
    # Sync
    echo "pacman sync..."
    if ! sudo pacman -Sy; then
        echo "ERROR: pacman error"
        exit 3
    fi
    # Download needed packages without installing
    echo
    echo "Download needed packages without installing..."
    if ! sudo pacman -w --noconfirm -Su; then
        echo "ERROR: pacman error"
        exit 3
    fi
elif [[ "$pkglist" != "" ]]; then
    targetlist=$(pacman -p --print-format '%n-%v' -S $pkglist)
    if [[ "$targetlist" == "" ]]; then
        echo "ERROR: package download list is empty"
        exit 3
    fi
    echo "Download needed packages without installing..."
    if ((diag != 1)); then
        if ! sudo pacman -w --noconfirm -S $pkglist; then
            echo "ERROR: pacman error"
            exit 3
        fi
    fi
fi
# Get list of packages in pacman cache
flist=$(find "$cachedir" -maxdepth 1 -type f -name "*.pkg.tar.?z")
if [[ "$flist" == "" ]]; then
    echo "      WARNING: No packages found in $cachedir"
    echo "      nothing to do: exiting..."
    exit 3
fi

if ((targets == 1)) && [[ "$targetlist" == "" ]]; then
    uptargets=$(LANG=C pacman -p --print-format '%n-%v' -Su)
    # deleting the ':: Starting full system upgrade...' header
    uptargets=$(echo $uptargets|cut -d ' ' -f6-)
    targetlist="$uptargets"
    if [[ "$targetlist" == "" ]]; then
        echo "ERROR: there are no targets for update"
        exit 3
    fi
fi
if [[ "$targetlist" != "" ]]; then
    echo
    echo "TARGET LIST:  (only these packages will be checked)"
    for t in $targetlist; do
	echo "$t"
	target+=("$t")
        if ! echo "$flist"|grep -q "$t"; then
            misstargets+="\n    $t"
        fi
    done
fi

# Get repo list
for repo in  core extra community community-staging community-testing \
     gnome-unstable kde-unstable multilib multilib-testing staging \
     testing; do
    if [[ -s "$dbpath/sync/$repo.db" ]]; then
        repolist+=" $repo"
    fi
done
if [[ "$repolist" == "" ]]; then
    echo "ERROR: No repos found in $dbpath/sync"
    exit 3
fi

# Display db timestamps
echo
echo "Timestamps:"
for repo in $repolist; do
    ts=$(stat -c %y "$dbpath/sync/$repo.db")
    echo "$dbpath/sync/$repo.db: ${ts/.000000000/}"
done
echo

trapexit()
{
    # remove temp folder
    if [[ -d "$tmp" ]]; then
        if ((keep != 1)) && ((diag != 1)); then
	    cd
            rm -rf "$tmp"
        else
            echo
            echo "Keeping temp files in $tmp"
        fi
        echo
        echo "paccheck stopped"
    fi
    exit 3
}

trap trapexit SIGINT SIGTERM SIGQUIT SIGHUP

# Download db files from mirrors

addtier1()
{
    for t in ${tier1[@]}; do
        if [[ "$t" == "$1" ]]; then
            return
        fi
    done
    tier1+=("$1")
}

istarget()
{
    if [[ "$targetlist" == "" ]]; then
        return 0
    fi
    for t in "${target[@]}"; do
        if [[ "$t" == "$1" ]]; then
            return 0
        fi
    done
    return 1
}

echo "========== DOWNLOADING ============"
if ((diag != 1)); then
    rm -rf "$tmp"
fi
if ! mkdir -p "$tmp"; then
    echo "ERROR: cannot create directory $tmp"
    exit 3
fi
echo
echo "Downloading actual official Mirror List"
if wget --no-verbose --tries=1 --connect-timeout=30 -O $tmp/actual-mirror.txt "http://www.archlinux.org/mirrorlist/all/"; then
    actualmok=1
fi

echo
echo "Downloading Mirror Overview page"
if wget --no-verbose --tries=1 --connect-timeout=30 -O $tmp/mirror-overview.html "http://www.archlinux.org/mirrors/"; then
    viewmok=1
fi

if ((actualmok == 1)); then
    x=0
    for m in "${mir[@]}"; do
	if ! grep -q "$m" $tmp/actual-mirror.txt; then
	    echo "Mirror $m is not found in the actual official Mirror List"
	    echo "removing it from the list..."
	    unset mir[$x]
	fi
	((x++))
    done
    if [[ "${mir[@]}" == "" ]]; then
	echo
	echo "No mirror was found valid"
	echo "a default mirror list will be used"
	unset mir
	mir+=("${defmir[@]}")
    fi
fi
for m in "${mir[@]}"; do
    if ((diag != 1)); then
        mdir="$m"
        mdir="${mdir#*://}"
        mdir="${mdir%%/*}"
        tdir="$tmp/mirror-$mdir"
        mkdir -p "$tdir"    
        cd "$tdir"
	# Get & parse mirror info
	unset infourl infomir country 
	echo
	echo -n "Seeking info on $mdir: "
	mdom="$mdir"
	if ((viewmok == 1)); then
	    while [[ "$mdom" != "${mdom/./}" ]]; do
		infourl="/mirrors/$mdom"
		infomir=$(grep --after-context=3 "$infourl" $tmp/mirror-overview.html)
		if [[ $infomir != "" ]]; then
		    break
		fi
		mdom="${mdom#*.}"
	    done
	fi
	if [[ $infomir != "" ]]; then
	    tier=$(echo $infomir|tr -d /|awk -v FS="<td>" '{print $4}')
	    if [[ "$tier" != "" ]]; then
		if [[ "$tier" == "Tier 1" ]]; then
		    addtier1 "$mdir"
		fi
		c=$(echo $infomir|tr -d /|awk -v FS="<td>" '{print $6}')
		if [[ "$c" != "" ]]; then
		    country="($c)"
		fi
		echo "FOUND"
		echo "$tier $country" > mirror-info.txt  
	    else
		echo "NOT FOUND"
	    fi
	else
	    echo "WARNING Could not retrieve mirror infos"
	fi    
	echo
	# Get mirror db's
	unset rmir
	for repo in $repolist; do
	    eval rmir+=("$m/$repo.db")
	done
	wget --no-verbose --tries=2 --connect-timeout=30 -N "${rmir[@]}"
    fi
done

echo

# Compare db files
echo "=========== ANALYZING ============="
for m in ${mir[@]}; do
    checkpkg=0
    mdir="$m"
    mdir="${mdir#*://}"
    mdir="${mdir%%/*}"
    tdir="$tmp/mirror-$mdir"
    touch $tdir/mirror-info.txt
    info=$(< "$tdir/mirror-info.txt")
    echo
    echo "$mdir:  $info"
    for repo in $repolist; do
        echo -n "    $repo.db: "
        ftest="$tdir/$repo.db"
        fvar="$dbpath/sync/$repo.db"
        if [[ ! -s "$ftest" ]]; then
            echo "DOWNLOAD FAILED"
            baddownload=1
        else
            if [[ "$(stat -c %Y "$ftest")" != "$(stat -c %Y "$fvar")" ]]; then
                echo -n "timestamp mismatch   "
            fi
            cmp -s "$ftest" "$fvar"
            err="$?"
            if [[ "$err" == "0" ]]; then
                echo "content OK"
            elif [[ "$err" == "1" ]]; then
                echo "CONTENT MISMATCH"
                contents=1
                checkpkg=1
            else
                echo "COMPARE ERROR"
                errors=1
            fi
        fi
    done
    if ((checkpkg == 1)); then
        # Mismatch so compare package version and desc
        echo "    Scanning package database (due to database mismatch)..."
        allok=1
        ccntok=0
        for repo in $repolist; do
	    mkdir -p "$tdir/db/$repo"
	    mkdir -p "$tdir/test/$repo"
        done
        for f in $flist; do
	    pkg="$(basename "$f")"
            pkg="${pkg%-$arch.pkg.tar.?z}"
            pkg="${pkg%-any.pkg.tar.?z}"
	    if ( istarget "$pkg" ); then
		foundrepo=0
		for repo in $repolist; do
		    cd $tdir/db/$repo
		    if tar xf $dbpath/sync/$repo.db $pkg/desc 2>/dev/null; then
			foundrepo=1
			dsync=$tdir/db/$repo/$pkg
			break
		    fi
		done
		if ((foundrepo == 1)); then
		    found=0
		    cd $tdir/test/$repo
		    if tar xf $tdir/$repo.db $pkg/desc 2>/dev/null; then
			found=1
			dtest=$tdir/test/$repo/$pkg
		    fi
		    if ((found == 1)); then
			cmp -s "$dtest/desc" "$dsync/desc"
			err="$?"
			if [[ "$err" == "1" ]]; then
			    echo "      $repo/$pkg: @@@@@@@@@@ MISMATCH @@@@@@@@@@@"
			    badpkgs="$badpkgs\n    $repo/$pkg  ($mdir)"
			    allok=0
			elif [[ "$err" == "0" ]]; then
			    ((ccntok++))
			    if ((verbose == 1)); then
				echo "      $repo/$pkg: OK"
			    fi
			else
			    echo "      $repo/$pkg: COMPARE ERROR"
			    errors=1
			    allok=0
			fi
		    else
			echo "      $repo/$pkg: MISSING"
			misspkgs="$misspkgs\n    $repo/$pkg  ($mdir)"
			allok=0
		    fi
		elif ((verbose == 1)); then
		    echo "      $pkg: expired from sync"
		fi
	    elif ((verbose == 1)); then
		echo "      $pkg: ignored - not a target"
	    fi
        done
        if ((allok == 1)); then
	    if ((ccntok == 0)); then
		echo "      (nothing to compare)"
	    elif ((ccntok == 1)); then
		echo "      OK - Package matches in database"
	    else
		echo "      OK - All $ccntok packages match in database"
	    fi
	else
	    if ((ccntok == 0)); then
		echo "      NO PACKAGE COULD BE FOUND MATCHING IN DATABASE"
	    elif ((ccntok == 1)); then
		echo "      one package matches in database"
	    else
		echo "      $ccntok packages match in database"
	    fi
        fi
    fi
done

# Check package sizes
if ((skipsize != 1)); then
    echo
    echo "Checking package sizes..."
    allok=1
    scntok=0
    if ((altsize != 1)); then
        if [[ "$(stat -f -c %T "$cachedir")" =~ btr ]]; then
            echo "NOTE: btrfs filesystem detected on $cachedir - switching"
            echo "      to slower alternate size method (--alt-size)."
            altsize=1
        fi
    fi
    for repo in $repolist; do
	mkdir -p "$tdir/db/$repo"
    done
    for f in $flist; do
	pkg="$(basename "$f")"
	pkg="${pkg%-$arch.pkg.tar.?z}"
	pkg="${pkg%-any.pkg.tar.?z}"
	if ( istarget "$pkg" ); then
	    foundrepo=0
	    for repo in $repolist; do
		cd $tdir/db/$repo
		if tar xf $dbpath/sync/$repo.db $pkg/desc 2>/dev/null; then
		    foundrepo=1
		    dsync=$tdir/db/$repo/$pkg
		    break
		fi
	    done
	    if ((foundrepo == 1)); then
		pkgsize=$(grep --after-context=1 %CSIZE% "$dsync/desc"|tail -1)
		if ((altsize != 1)); then
		    actualsize="$(stat -c %s "$f")"
		else
		    actualsize=$(cat "$f" | wc -c)
		fi
		if [[ "$pkgsize" != "" ]]; then
		    if [[ "$actualsize" != "$pkgsize" ]]; then
			echo "    $repo/$pkg: @@@@@@@@ SIZE MISMATCH @@@@@@@@@"
			sizepkgs="$sizepkgs\n    $repo/$pkg  (cache $(stat -c %s "$f") != db $pkgsize)"
			allok=0
		    else
			((scntok++))
			if ((verbose == 1)); then
			    echo "    $repo/$pkg: OK"
			fi
		    fi
		else
		    echo "    $repo/$pkg: ERROR: no size found in database"
		    errors=1
		    allok=0
		fi
	    elif ((verbose == 1)); then
		echo "      $pkg: expired from sync"
	    fi
	elif ((verbose == 1)); then
	    echo "    $pkg: ignored - not a target"
	fi
    done
    if ((allok == 1)); then
	if ((scntok == 0)); then
	    echo "    (nothing to check)"
	elif ((scntok == 1)); then
	    echo "    OK - Package is the correct size"
	else
	    echo "    OK - All $scntok packages are the correct size"
	fi
    else
        if ((scntok == 0)); then
            echo "    NO PACKAGE COULD BE FOUND THE CORRECT SIZE"
        elif ((scntok == 1)); then
            echo "    One package was found the correct size"
        else
            echo "    $scntok packages were found the correct size"
        fi
    fi    
fi

# Full download compare
if [[ "${cmpmir[@]}" != "" ]]; then
    echo
    echo "=========== COMPARING ============="
    if ((actualmok == 1)); then
	x=0
	for m in "${cmpmir[@]}"; do
            if [[ "${m:0:1}" != "/" ]]; then
		if ! grep -q "$m" $tmp/actual-mirror.txt; then
		    echo "Mirror $m is not found in the actual official Mirror List"
		    echo "removing it from the compare list..."
		    unset cmpmir[$x]
		fi
	    fi
	    ((x++))
	done
	if [[ "${cmpmir[@]}" == "" ]]; then
	    echo
	    echo "No mirror left in compare mirror list"
	    echo "no compare wil be done..."
	fi
    fi
fi
for m in "${cmpmir[@]}"; do
    if [[ "${m:0:1}" == "/" ]]; then
        # local compare
        # files must already be downloaded to localdir/pkg/
        localcompare=1
        tdir="$m"
        mdir="$m"
    else
        localcompare=0
        mdir="$m"
        mdir="${mdir#*://}"
        mdir="${mdir%%/*}"
        tdir="$tmp/compare-$mdir"
        mkdir -p "$tdir"
        echo
        echo "Downloading full packages on $mdir:"
        # Prepare download
        echo "create-dirs" > "$tdir/curl.conf"
        echo "connect-timeout=30" >> "$tdir/curl.conf"
        echo "fail" >> "$tdir/curl.conf"
        #echo "-#" >> "$tdir/curl.conf"  # progress bar
    fi
    unset cpkg
    for repo in $repolist; do
	mkdir -p "$tdir/db/$repo"
    done
    for f in $flist; do
	pkgf="$(basename "$f")"
	pkg="${pkgf%-$arch.pkg.tar.?z}"
	pkg="${pkg%-any.pkg.tar.?z}"
	if ( istarget "$pkg" ); then
	    foundrepo=0
	    for repo in $repolist; do
		cd $tdir/db/$repo
		if tar xf $dbpath/sync/$repo.db $pkg/desc 2>/dev/null; then
		    foundrepo=1
		    break
		fi
	    done
	    if ((foundrepo == 1)); then
		if ((localcompare != 1)); then
		    echo "-o pkg/$pkgf" >> "$tdir/curl.conf"
		    eval echo "url=$m/$pkgf" >> "$tdir/curl.conf"
		fi
		cpkg+=("$pkgf")
		if ((brief == 1)) && ((${#cpkg[@]} > 3)); then
		    echo "    WARNING: DIAGNOSTIC BRIEF MODE - NOT ALL FILES TESTED"
		    break
		fi
	    elif ((verbose == 1)); then
		echo "    $repo/$pkgf: expired from sync"
	    fi
	elif ((verbose == 1)); then
	    echo "    $pkg: ignored - not a target"
	fi
    done        
    # Download
    cd "$tdir"
    if ((diag != 1)) && ((localcompare == 0)) && ((${#cpkg[@]} != 0)); then
        curl --config "$tdir/curl.conf"
        if ((brief == 1)); then
            echo "Paused - press Enter to compare..."
            read
        fi
    elif ((${#cpkg[@]} == 0)) && ((localcompare == 0)); then
        echo "    (nothing to download)"
    fi
    # Compare
    echo
    echo "Comparing full packages on $mdir:"
    cmpmsg=0
    ccntok=0
    for p in "${cpkg[@]}"; do
        pname="${p%-$arch.pkg.tar.?z}"
        pname="${pname%-any.pkg.tar.?z}"
        if [[ ! -s "$tdir/pkg/$p" ]]; then
            echo "    $pname: DOWNLOAD FAILED"
            baddownload=1
            cmpmsg=1
        else
            cmp -s "$tdir/pkg/$p" "$cachedir/$p"
            err=$?
            if [[ "$err" == "1" ]]; then
                echo "    $pname: @@@@@@ MISMATCH @@@@@@@"
                badcmp="$badcmp\n    $pname  ($mdir)"
                cmpmsg=1
            elif [[ "$err" == "0" ]]; then
		((ccntok++))
                if ((verbose == 1)); then
                    echo "    $pname: OK"
                fi
            else
                echo "    $pname: COMPARE ERROR"
                errors=1
                cmpmsg=1
            fi
        fi
    done
    echo
    if ((cmpmsg != 1)); then
        if ((ccntok == 0)); then
	    echo "    (nothing to compare)"
        elif ((ccntok == 1)); then
            echo "    OK - Package is present and identical"
        else
            echo "    OK - All $ccntok packages are present and identical"
        fi
    else
        if ((ccntok == 0)); then
            echo "    NO PACKAGE COULD BE FOUND PRESENT AND IDENTICAL"
        elif ((ccntok == 1)); then
            echo "    One package is present and identical"
        else
            echo "    $ccntok packages are present and identical"
        fi
    fi
done

# remove temp folder
if ((keep != 1)) && ((diag != 1)); then
    cd
    rm -rf "$tmp"
else
    echo
    echo "Keeping temp files in $tmp"
fi

echo
echo "============ SUMMARY =============="
echo
if [[ "$badpkgs" != "" ]]; then
    echo "@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@"
    echo "THE FOLLOWING PACKAGES HAVE MISMATCHES - THIS IS BAD - this may indicate"
    echo "compromised mirrors (including your default pacman mirror):"
    echo -e "$badpkgs"
    echo "@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@"
    echo
    error3=1
fi
if [[ "$sizepkgs" != "" ]]; then
    echo "@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@"
    echo "THE FOLLOWING PACKAGES IN PACMAN'S PKG CACHE ARE THE WRONG SIZE - this"
    echo "indicates they are corrupt or have been modified or the database has"
    echo "been tampered with:"
    echo -e "$sizepkgs"
    echo "@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@"
    echo
    error3=1
fi
if [[ "$badcmp" != "" ]]; then
    echo "@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@"
    echo "THE FOLLOWING PACKAGES HAVE FULL COMPARE MISMATCHES - THIS IS BAD - this"
    echo "may indicate compromised mirrors (including your default pacman mirror):"
    echo -e "$badcmp"
    echo "@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@"
    echo
    error3=1
fi
if ((errors == 1)); then
    echo "THERE WERE ERRORS - This indicates one or more malfunctions."
    echo
    error1=1
fi
if ((baddownload == 1)); then
    echo "THERE WERE DOWNLOAD FAILURES - This indicates unresponsive mirror(s) or"
    echo "files missing on the mirror(s)."
    echo
    error1=1
fi
if [[ "$misstargets" != "" ]]; then
    echo "THE FOLLOWING TARGETS ARE NOT IN PACMAN'S PKG CACHE - This means they"
    echo "could not be tested:"
    echo -e "$misstargets"
    echo
    error1=1
fi
if [[ "$misspkgs" != "" ]]; then
    echo "THE FOLLOWING PACKAGES ARE MISSING FROM THE INDICATED MIRROR - If they"
    echo "are listed as missing from all mirrors above, this indicates they could"
    echo "not be tested:"
    echo -e "$misspkgs"
    echo
    error2=1
fi
if ((contents == 1)); then
    echo "THERE WERE DATABASE CONTENT MISMATCHES - This usually indicates some"
    echo "mirrors were out of date, but alone does not indicate compromised"
    echo "mirrors. See http://www.archlinux.org/mirrors/status/"
    echo
    error1=1
fi

if [[ "${mir[1]}" == "" ]]; then
    echo "WARNING: USING MORE THAN ONE MIRROR IS RECOMMENDED"
    echo
    error1=1
elif ((${#tier1[@]} < 2)); then
    echo "WARNING: could not verify that more than one Tier 1 mirrors are in your"
    echo "mirror list. See http://www.archlinux.org/mirrors/"
    echo
    error1=1
elif [[ "$badpkgs$misspkgs" == "" ]] && ((errors + baddownload + contents == 0)); then
    echo "All OK."
    echo
fi

if ((error3 == 1)); then
    err=3
elif ((error2 == 1)); then
    err=2
elif ((error1 == 1)); then
    err=1
else
    err=0
fi

if ((err > 2)); then
    echo "System update is NOT recommended until the above issues are addressed."
    echo
fi

if ((diag == 1)) || ((brief == 1)); then
    echo "WARNING: DIAGNOSTIC MODE IN USE - results may be incomplete"
fi

if [[ "$pkglist" != "" ]]; then
    echo
    echo "Install Package List:$pkglist"
    echo "Targets: "
    for t in $targetlist; do
	echo "$t"
    done
    echo
    if ((err < 3)) && ((diag != 1)); then
        echo -n "Proceed with installation? [Y/n] "
        read -n 1 s
        echo
        if [[ "$s" == "n" ]] || [[ "$s" == "N" ]]; then
            exit $err
        fi
    else
        echo -n "Proceed with installation? [y/N] "
        read -n 1 s
        echo
        if [[ "$s" == "" ]] || [[ "$s" == "n" ]] || [[ "$s" == "N" ]]; then
            exit $err
        fi
    fi
    echo
    sudo pacman --noconfirm -S $pkglist
    exit $?
fi
exit $err
