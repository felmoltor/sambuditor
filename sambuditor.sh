#!/bin/bash

# Listar unidades de los shares e intenta conectar con el usuario nulo
# TODO: Ya que estamos repasando todas las unidades de los discos compartidos, podriamos sacar estadisticas de los tipos de ficheros que estan almacenando los usuarios. Por informacion para presentar en las reuniones

ip_list=$1
domain=$2
user=$3
password=$4
domain_user=$domain"\\"$user
null_user=0

###############
# CONFIG VARS #
###############

RESULT_DIR="/tmp/sambuditor"        # Directorio donde se guardaran los LOGS
MATCHES_DIR=$RESULT_DIR"/Matches"
MAX_COPY_FILE_BYTES=716800                  # 700 KB
COPY_MATCHES=1                              # Donde se guardan los ficheros donde hay matches
FIND_READABLES=1
FIND_WRITABLES=0
FIND_DEEP=3
JUICY_SEARCH=1
MAX_JUICY_SEARCH_FILESIZE=2097152           # 2MB. 0 = No size limit
FILETYPE_BLACK_LIST="exe,dll,rar,zip,7z,png,jpg,jpeg,bmp,tiff,tif,gif,ppm,pgm,svg,pam,log"
SEARCH_REGEXP="pwd|pass|contrase"
FILE_EXT_FILTER=""
DISK_WHITELIST="./diskwhitelist.txt"
PATH_WHITELIST="./pathwhitelist.txt"

#############
# FUNCTIONS #
#############

function printBanner
{
    local b="
  _________             ___.             .___.__  __                        ____    _______   
 /   _____/____    _____\\_ |__  __ __  __| _/|__|/  |_  ___________  ___  _/_   |   \\   _  \\  
 \\_____  \\\\__  \\  /     \\| __ \\|  |  \\/ __ | |  \\   __\\/  _ \\_  __ \\ \\  \\/ /|   |   /  /_\\  \\ 
 /        \\/ __ \\|  Y Y  \\ \\_\\ \\  |  / /_/ | |  ||  | (  <_> )  | \\/  \\   / |   |   \\  \\_/   \\
/_______  (____  /__|_|  /___  /____/\\____ | |__||__|  \\____/|__|      \\_/  |___| /\\ \\_____  /
        \\/     \\/      \\/    \\/           \\/                                      \\/       \\/ 
"

    echo "$b"
    echo
    echo "##########################################################################"
    echo "# Author: Felipe Molina (@felmoltor)                                     #"
    echo "# Date: July 2013                                                        #"
    echo "# License: GPLv3 (https://www.gnu.org/licenses/gpl-3.0-standalone.html)  #"
    echo "##########################################################################"
    echo
}

function allowedInWhiteListFile
{
    local allowed=0
    keyword=$1
    whitelistfile=$2

    # Si en el fichero de la lista blanca no existe o en el aparece un asterisco, significa que todos los discos estan permitidos
    if [[ -f $whitelistfile ]];then
        if [[ $(grep "^\*$" $whitelistfile | wc -l) > 0 ]];then
            echo "We have permissions to mount all shared disk/paths ('*' found in whitelist)"
            allowed=1
        else
            # Buscamos el nombre del disco compartido en el fichero
            if [[ $(grep "^$disk$" $whitelistfile | wc -l) > 0 ]];then
                allowed=1
            else
                allowed=0
            fi
        fi
    else
        "White list file ($whitelistfile) does not exists. We have NO PERMISSIONS to mount anything."
        allowed=0
    fi

    return $allowed
}

function isPathInWhiteList
{
    local allowed=0
    path=$1

    allowedInWhiteListFile $path $PATH_WHITELIST
    allowed=$?
    return $allowed
}

function isDiskInWhiteList
{
    local allowed=0
    disk=$1

    allowedInWhiteListFile $disk $DISK_WHITELIST
    allowed=$?
    return $allowed
}

function setFindExtensionFilter
{
    if [[ ${#FILETYPE_BLACK_LIST} > 0 ]]
    then
        FILE_EXT_FILTER=$(echo $FILETYPE_BLACK_LIST | sed 's/,/" ! -iname "*./g')
        FILE_EXT_FILTER="! -iname \"*."$FILE_EXT_FILTER"\" "
    fi
}

####################
# CHECK PARAMETROS #
####################

printBanner
setFindExtensionFilter

if [[ "$user" = "" ]]
then
    # Se hace con el usuario nulo
    null_user=1
    domain_user="Null"
else
    null_user=0
    if  [[ $password = "" ]]
    then
        echo "Error. Se ha especificado un usuario pero no su contrasenna"
        exit
    fi
fi

####################
# INIT DIRECTORIES #
####################
# Creamos fichero de resultados si no existe
if [[ ! -d $MATCHES_DIR ]]
then
    mkdir -p $MATCHES_DIR
    if [[ $? -gt 0 ]]
    then
        echo "Error. We couldn't create folder '$MATCHES_DIR' to store matched files. Check your write permissions."
        exit 1
    fi
fi

# Comprobamos que existe el fichero con el listado de IP
if [[ -f $ip_list ]]
then
    for target_ip in `cat $ip_list`
    do
        # Vaciamos ficheros de log
        echo -n "" > "$RESULT_DIR/$target_ip.shares.txt"
        echo -n "" > "$RESULT_DIR/$target_ip.shares.mounted.txt"

        echo "==========================="
        echo "$target_ip:"
        n_shares=0
        if [[ $null_user = 1 ]]
        then
            n_shares=$(smbclient -L $target_ip -U "" -N -g | grep "^Disk" | cut -f2 -d"|" | wc -l)
        else
            n_shares=$(smbclient -L $target_ip -U $user%$password -W $domain -g | grep "^Disk" | cut -f2 -d"|" | wc -l)
        fi

        echo "$target_ip has $n_shares shared disk."
        if [[ $n_shares > 0 ]]
        then
            if [[ $null_user = 1 ]]
            then
                echo "Listing $target_ip shares with Null user..."
                smbclient -L $target_ip -U "" -N -g | grep "^Disk" | cut -f2 -d"|" >> "$RESULT_DIR/$target_ip.shares.txt"
            else
                echo "Listing $target_ip shares with user $domain\\$user..."
                smbclient -L $target_ip -U $user%$password -W $domain -g | grep "^Disk" | cut -f2 -d"|" >> "$RESULT_DIR/$target_ip.shares.txt"
            fi

            cat "$RESULT_DIR/$target_ip.shares.txt" | while read share
            #for share in `cat "$RESULT_DIR/$target_ip.shares.txt"`
            do 
            
                # Check if this disk ($share) is in the whitelist of allowed disk to explore
                isDiskInWhiteList $share
                isdiskinwl=$?
                if [[ $isdiskinwl != 1 ]];then
                    echo "$disk is not in the whitelist file '$DISK_WHITELIST'. Skipping it..."
                    continue
                fi

                # Mount the share
                to_mount="//$target_ip/$share"
                sharepath="${target_ip}_${share}"
                tmpshare="$RESULT_DIR/$sharepath"
                
                 # Vaciamos ficheros de shares
                echo -n "" > "$RESULT_DIR/$sharepath.shares.matches.txt"
                echo -n "" > "$RESULT_DIR/$sharepath.shares.readable.txt"

                if [[ ! -d "$tmpshare" ]] 
                then
                    mkdir -p "$tmpshare"
                fi
                
                # Intentamos montar el share
                if [[ $null_user = 1 ]]
                then
                    echo "Mounting $to_mount with Null user..."
                    mount -t cifs "$to_mount" "$tmpshare" -o sec=none,guest,ro
                else
                    echo "Mounting $to_mount with user $domain\\$user..."
                    mount -t cifs "$to_mount" "$tmpshare" -o user=$user,workgroup=$domain,password=$password,ro
                fi

                if [[ "$?" -eq "0" ]]
                then
                    # Hacemos busqueda y mostramos estado
                    echo "$to_mount:OK" >> "$RESULT_DIR/$target_ip.shares.mounted.txt"
                    echo "$to_mount was successfuly mounted. Listing readable files in this share..."
                    cd $tmpshare 
             
                    if [[ $FIND_READABLES == 1 ]]
                    then
                        # Buscamos cualquier fichero con permisos de lectura para cualquiera
                        eval find . -maxdepth $FIND_DEEP -type f $FILE_EXT_FILTER -size -$MAX_JUICY_SEARCH_FILESIZE -perm /u+r >> "$RESULT_DIR/$sharepath.shares.readable.txt"
                        n_ficheros_legibles=$(cat "$RESULT_DIR/$sharepath.shares.readable.txt" | wc -l)
                        echo "There are '$n_ficheros_legibles' readable files in '$to_mount'. (Maximum search deep is $FIND_DEEP)"
                        
                        if [[ $n_ficheros_legibles > 0 ]]
                        then
                            if [[ $JUICY_SEARCH == 1 ]]
                            then
                                # Add a new condition to skip the paths not contained in whitelist
                                # Find only files with matching paths in the whitelist
                                for pathinwl in `cat $PATH_WHITELIST | sort -u`;do
                                    echo "Looking in '$to_mount' files with matching path '$pathinwl' containing the explressions '$SEARCH_REGEXP'"
                                    find $to_mount -type f -path "*$pathinwl*" -print -perm /u+r | xargs grep -il -E "$SEARCH_REGEXP" --binary-files=without-match >> "$RESULT_DIR/$sharepath.shares.matches.txt"
                                    # Si el grep encuentra algo devuelve 0
                                    if [[ "$?" -eq "0" ]]
                                    then
                                        echo "Matches were found in the folowing files: "
                                        cat "$RESULT_DIR/$sharepath.shares.matches.txt"
                                        # Si el directorio donde guardar los ficheros no existe, lo creamos
                                        dirmatches_share="$MATCHES_DIR/$sharepath"
                                        if [[ ! -d "$dirmatches_share" ]]
                                        then
                                            mkdir -p "$dirmatches_share"

                                        fi

                                        # Para cada fichero que concuerda, hacemos una copia si su tamanno es pequeño (< 700 kB)
                                        # for matched_file in `cat "$RESULT_DIR/$sharepath.shares.matches.txt"`
                                        cat "$RESULT_DIR/$sharepath.shares.matches.txt" | while read matched_file
                                        do
                                            matched_file_size=$(stat -c%s "$matched_file")
                                            # echo "Fichero '$matched_file' con tamanno '$matched_file_size'"
                                            
                                            if [[ $matched_file_size < $MAX_COPY_FILE_BYTES ]]
                                            then
                                                echo "Copying '$matched_file' to $dirmatches_share..."
                                                cp "$matched_file" "$dirmatches_share"
                                            else
                                                echo "Sice of '$matched_file' ($matched_file_size) reach the size limit ($MAX_COPY_FILE_BYTES) to automaticaly copy it. It's not copied to $dirmatches_share"
                                            fi
                                        done
                                    else
                                        echo "No matches were found in $to_mount"
                                    fi    
                                done
                            else
                                echo "We are not doing search of 'juicy files'"
                            fi # Del Juicy Search
                        else
                            echo "There are no readable files in $to_mount for this user"
                        fi
                    else
                        echo "We are not looking for readable files in $to_mount"
                    fi # Del FIND_READABLES

                    cd $RESULT_DIR
                    # Desmontamos share
                    echo "Unmounting $to_mount and deleting folder $tmpshare..."
                    umount $to_mount 
                    rmdir $tmpshare
                else
                    echo "$to_mount:KO" >> "$RESULT_DIR/$target_ip.shares.mounted.txt"
                    echo "$to_mount couldn't be mounted with $domain_user. Check for your permissions."
                fi
               
            done
        else
            echo "<NO SHARES>"
        fi

    done
else
    echo "Error. Usage:"
    echo "$0 <file_with_ips> [<DOMAIN> <User> <Password>]"
    exit
fi

