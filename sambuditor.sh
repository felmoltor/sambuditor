#!/bin/bash

# Listar unidades de los shares e intenta conectar con el usuario nulo

ip_list=$1
search_regexp=$5
domain=$2
user=$3
password=$4
domain_user=$domain"\\"$user
null_user=0

############
# GLOBALES #
############
RESULT_DIR="/tmp/busca_shares"   # Directorio donde se guardaran los LOGS
MATCHES_DIR=$RESULT_DIR"/Matches"
COPY_MATCHES=1      # Guardamos los ficheros donde hay matches
FIND_READABLES=1
FIND_WRITABLES=0
FIND_DEEP=4
JUICY_SEARCH=1

####################
# CHECK PARAMETROS #
####################

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

# Comprobamos si ha especificado una regexp
#if [[ "$search_regexp" -eq "" ]]
#then
    search_regexp="pwd|pass|contrase"
#fi

####################
# INIT DIRECTORIES #
####################
# Creamos fichero de resultados si no existe
if [[ ! -d $MATCHES_DIR ]]
then
    mkdir -p $MATCHES_DIR
    if [[ $? -gt 0 ]]
    then
        echo "Error. No se pudo crear el directorio de resultados en $MATCHES_DIR"
        exit 1
    fi
fi


# Comprobamos que existe el fichero con el listado de IP
if [[ -f $ip_list ]]
then
    for target_ip in `cat $ip_list`
    do
        # Vaciamos ficheros de log
        echo -n "" > $RESULT_DIR"/"$target_ip.shares.txt
        echo -n "" > $RESULT_DIR"/"$target_ip.shares.mounted.txt

        echo "==========================="
        echo "$target_ip:"
        n_shares=0
        if [[ $null_user = 1 ]]
        then
            n_shares=$(smbclient -L $target_ip -U "" -N | grep "Disk" | awk '{print $1}' | wc -l)
        else
            n_shares=$(smbclient -L $target_ip -U $user%$password -W $domain | grep "Disk" | awk '{print $1}' | wc -l)
        fi

        echo "$target_ip has $n_shares shared disk."
        if [[ $n_shares > 0 ]]
        then
            if [[ $null_user = 1 ]]
            then
                echo "Listing $target_ip shares with Null user..."
                echo $(smbclient -L $target_ip -U "" -N | grep "Disk" | awk '{print $1}') >> $target_ip.shares.txt
            else
                echo "Listing $target_ip shares with user $domain\\$user..."
                echo  $(smbclient -L $target_ip -U $user%$password -W $domain | grep "Disk" | awk '{print $1}') >> $target_ip.shares.txt
            fi
            for share in `cat $target_ip.shares.txt`
            do 
                # Montamos el share 
                to_mount="//$target_ip/$share"
                sharepath=$target_ip"_"$share
                tmpshare=$RESULT_DIR"/"$sharepath
                
                 # Vaciamos ficheros de shares
                echo -n "" > $RESULT_DIR"/"$sharepath.shares.matches.txt
                echo -n "" > $RESULT_DIR"/"$sharepath.shares.readable.txt

                if [[ ! -d $tmpshare ]] 
                then
                    mkdir -p $tmpshare
                fi
                
                # Intentamos montar el share
                if [[ $null_user = 1 ]]
                then
                    echo "Mounting $to_mount with Null user..."
                    mount -t cifs $to_mount $tmpshare -o sec=none,guest,ro #guest,ro
                else
                    echo "Mounting $to_mount with user $domain\\$user..."
                    mount -t cifs $to_mount $tmpshare -o user=$user,workgroup=$domain,password=$password,ro
                fi

                if [[ "$?" -eq "0" ]]
                then
                    # Hacemos busqueda y mostramos estado
                    echo "$to_mount:OK" >> $RESULT_DIR"/"$target_ip.shares.mounted.txt
                    echo "$to_mount was successfuly mounted. Listing files in this share..."
                    cd $tmpshare 
             
                    if [[ $FIND_READABLES == 1 ]]
                    then
                        # Buscamos cualquier fichero con permisos de lectura para cualquiera
                        find . -type f -perm /u+r -maxdepth $FIND_DEEP >> $RESULT_DIR"/"$sharepath.shares.readable.txt
                        n_ficheros_legibles=$(cat $RESULT_DIR"/"$sharepath.shares.readable.txt | wc -l)
                        echo "There are '$n_ficheros_legibles' readable files in '$to_mount'. (Maximum search deep is $FIND_DEEP)"
                        # Si hay ficheros legibles hacemos el grep en busca de "passw|contrase"
                            
                        if [[ $n_ficheros_legibles > 0 ]]
                        then
                            if [[ $JUICY_SEARCH == 1 ]]
                            then
                                echo "Looking in $to_mount the expresion '$search_regexp'..."
                                grep -iElr "$search_regexp" -r . >> $RESULT_DIR"/"$sharepath.shares.matches.txt
                                # Si el grep encuentra algo devuelve 0
                                if [[ "$?" -eq "0" ]]
                                then
                                    echo "Matches were found in the folowing files: "
                                    cat $RESULT_DIR"/"$sharepath.shares.matches.txt
                                    # Si el directorio donde guardar los ficheros no existe, lo creamos
                                    dirmatches_share=$MATCHES_DIR"/"$sharepath 
                                    if [[ ! -d $dirmatches_share ]]
                                    then
                                        mkdir -p $dirmatches_share
                                    fi

                                    # Para cada fichero que concuerda, hacemos una copia si su tamanno es pequeño (< 700 kB)
                                    for matched_file in `cat $RESULT_DIR"/"$sharepath.shares.matches.txt`
                                    do
                                        if [[ $(stat -c%s "$matched_file") -lt 716800 ]]
                                        then
                                            echo "Copying '$matched_file' to $dirmatches_share"
                                            cp $matched_file $dirmatches_share
                                        else
                                            echo "Sice of $matched_file reach the size limit to automaticaly copy it. It's not copied to $dirmatches_share"
                                        fi
                                    done
                                else
                                    echo "No matches were found in $to_mount"
                                fi
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
                    echo "$to_mount:KO" >> $RESULT_DIR"/"$target_ip.shares.mounted.txt
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

