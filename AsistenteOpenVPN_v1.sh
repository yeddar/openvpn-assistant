#!/bin/bash

if [[ "$EUID" -ne 0 ]]; then
	echo "Error. Tienes que ser administrador."
	exit
fi

iniciar=1
cliente=2
salir=3
op=-1
# Si OpenVPN está instalado se arranca el proceso de configuración
while [[ "$op" != "$salir" ]]; do
	clear
	echo "Asistente de configuración de OpenVPN"
	echo "	1) Iniciar configuración inicial"
	echo "	2) Añadir cliente"
	echo "	3) Salir"
	read -p "Elige una opción: " op
	until [[ -z "$op" ||"$op" =~ ^[1-3]$ ]]; do	
		echo "$op: invalid selection."
		read -p "Elige una opción: " op
	done
	clear
	case "$op" in
		"$iniciar")
		echo
		echo "En el proceso de configuración se te pedirán datos y contraseñas para la generación de certificados. Es importante recordar las contraseñas que vas a introducir."

		read -p "Introduce la IPv4 que usarás para el servidor OpenVPN: " ip

		echo
		echo "¿Qué protocolo quieres usar para las conexiones con el servidor OpenVPN?"
		echo "	1) UDP (recomendado)"
		echo "	2) TCP"
		read -p "protocolo [1]: " protocol

		until [[ -z "$protocol" || "$protocol" =~ ^[12]$ ]]; do
			echo "$protocol: invalid selection."
			read -p "Protocol [1]: " protocol
		done

		case "$protocol" in
			1|"")
			protocol=udp
			;;

			2)
			protocol=tcp
			;;
		esac
		echo 
		echo "*** Protocolo seleccionado: $protocol ***"
		echo
		echo "En qué puerto quieres que escuche el servidor OpenVPN?"
		read -p "Puerto [1194]: " port
		if [[ -z "$port" ]]; then
		  port="1194"
		fi
		echo
		echo "*** Puerto seleccionado: $port ***"
		echo
		echo "Qué servidores DNS quieres usar para la VPN?"
		echo "   1) OpenDNS (recomendado)"
		echo "   2) Google"

		read -p "DNS [1]: " dns
		until [[ -z "$dns" || "$dns" =~ ^[1-2]$ ]]; do
			echo "Selecciona una opción válida"
			read -p "DNS [1]: " dns
		done
		
		echo
		echo "Todo listo para la instalación."
		read -n1 -r -p "Presiona una tecla para continuar..."
		echo
		echo "Instalando software necesario..."

		# Instalación de software necesario
		sudo apt-get install openvpn easy-rsa iptables -y

		# Creación de directorio de la CA
		make-cadir ~/openvpn-ca
		cd ~/openvpn-ca

		# Creación de la CA y los certificados
		#
		echo "A continuación se creará la autoridad de certificación."
		read -p "PAÍS [ES]: " country
		if [[ "-z $country" ]]; then
			country="ES"
		fi
		read -p "PROVINCIA [CS]: " province
		if [[ "-z $province" ]]; then
			province="CS"
		fi
		read -p "CIUDAD [CS]: " city
		if [[ "-z $city" ]]; then
			city="CS"
		fi
		read -p "ORGANIZACIÓN [MyOrganization]: " organization
		if [[ "-z $organization" ]]; then
			organization="MyOrganization"
		fi
		read -p "EMAIL [me@myhost.mydomain]: " email
		if [[ "-z $email" ]]; then
			email="me@myhost.mydomain"
		fi
		read -p "UNIDAD ORGANIZACIONAL [MyOrganizationalUnit]: " organizationalUnit
		if [[ "-z $organizationalUnit" ]]; then
			organizationalUnit="MyOrganizationalUnit"
		fi
		read -p "NOMBRE [server]: " name
		if [[ "-z $server" ]]; then
			server="server"
		fi

		# Modifica datos de la CA
		sed -i 's/KEY_COUNTRY="US"/KEY_COUNTRY="'$country'"/g' ./vars
		sed -i 's/KEY_PROVINCE="CA"/KEY_PROVINCE="'$province'"/g' ./vars
		sed -i 's/KEY_CITY="SanFrancisco"/KEY_CITY="'$city'"/g' ./vars
		sed -i 's/KEY_ORG="Fort-Funston"/KEY_ORG="'$organization'"/g' ./vars
		sed -i 's/KEY_EMAIL="me@myhost.mydomain"/KEY_EMAIL="'$email'"/g' ./vars
		sed -i 's/KEY_OU="MyOrganizationalUnit"/KEY_OU="'$organizationalUnit'"/g' ./vars
		sed -i 's/KEY_NAME="EasyRSA"/KEY_NAME="'$server'"/g' ./vars

		# Obtiene datos de la CA
		source ./vars
		# Limpiado del directorio
		./clean-all
		# Construye CA a partir del fichero vars
		./build-ca --batch nopass
		#Crea llave privada y certificado del servidor
		./build-key-server $server
		# Generar claves Diffie-Hellman
		./build-dh
		# Generar firma HMAC
		openvpn --genkey --secret keys/ta.key
		# Copiar llaves al directorio /etc/openvpn
		cd ~/openvpn-ca/keys
		cp ca.crt $server.crt $server.key ta.key dh2048.pem /etc/openvpn

		
		# Fichero de configuración OpenVPN
		config_file=/etc/openvpn/server.conf
		echo 'port 1194
proto udp
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh2048.pem
server 10.8.0.0 255.255.255.0
ifconfig-pool-persist ipp.txt' > /etc/openvpn/server.conf
		echo 'push "redirect-gateway def1 bypass-dhcp"' >> /etc/openvpn/server.conf
		case "$dns" in
		  1|"")
		    echo 'push "dhcp-option DNS 208.67.222.222"' >> /etc/openvpn/server.conf
		    echo 'push "dhcp-option DNS 208.67.220.220"' >> /etc/openvpn/server.conf
		    ;;
		  2)
		    echo 'push "dhcp-option DNS 8.8.8.8"' >> /etc/openvpn/server.conf
		    echo 'push "dhcp-option DNS 8.8.4.4"' >> /etc/openvpn/server.conf
		    ;;
		esac
		echo 'keepalive 10 120
tls-auth ta.key 0
cipher AES-128-CBC
auth SHA256
comp-lzo
user nobody
group nogroup
persist-key
persist-tun
status openvpn-status.log
verb 3' >> /etc/openvpn/server.conf

		
	
		#Permitir redireccionamiento IP
		sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/g' /etc/sysctl.conf

		# Arrancar servicio
		systemctl stop openvpn@server
		systemctl start openvpn@server
		systemctl enable openvpn@server
		
				
		# Crear infraestructura de configuración de los clientes
		mkdir -p ~/client-configs/files
 		chmod 700 ~/client-configs/files
		cp /usr/share/doc/openvpn/examples/sample-config-files/client.conf ~/client-configs/base.conf
		echo "client
dev tun
proto $protocol
remote $ip $port
resolv-retry infinite
nobind
user nobody
group nogroup
persist-key
persist-tun
#ca ca.crt
#cert client.crt
#key client.key
remote-cert-tls server
cipher AES-128-CBC
auth SHA256
comp-lzo
verb 3
key-direction 1" > ~/client-configs/base.conf
		
		clear
		echo "Servidor configurado."
		read -n1 -r -p "Presiona una tecla para continuar..."
		;;
		# Creación de cliente
		"$cliente")
		if [[ ! -e /etc/openvpn/server.conf ]]; then
			echo "Error. OpenVPN no está instalado."
			exit
		fi
		if [[ ! -d ~/openvpn-ca || ! -f ~/client-configs/base.conf ]]; then
			echo "No existen los directorios de configuración. Debes iniciar la configuración inicial (opción $inicial)"
		fi
		read -p "Nombre del cliente OpenVPN: " client
		until [[ ! -z "$client" ]]; do
			echo "Tienes que introducir un nombre válido."
			read -p "Nombre del cliente OpenVPN: " client
		done
		
		# Crear llaves para cliente
		cd ~/openvpn-ca
		source ./vars
		./build-key-pass $client

		# Generar fichero de configuración para cliente
		base_config=~/client-configs/base.conf
		key_dir=~/openvpn-ca/keys
		output_dir=~/client-configs/files
		
		
		cat ${base_config} \
		    <(echo -e '<ca>') \
		    ${key_dir}/ca.crt \
		    <(echo -e '</ca>\n<cert>') \
		    ${key_dir}/${client}.crt \
		    <(echo -e '</cert>\n<key>') \
		    ${key_dir}/${client}.key \
		    <(echo -e '</key>\n<tls-auth>') \
		    ${key_dir}/ta.key \
		    <(echo -e '</tls-auth>') \
		    > ${output_dir}/${client}.ovpn
		clear
		echo "Se ha generado el fichero de configuración '$output_dir/$client.ovpn'."
		echo "Este fichero contiene llaves, certificados y configuración necesaria para el cliente." 
		echo "Debes transferir este fichero al equipo cliente de forma segura."
		read -n1 -r -p "Presiona una tecla para continuar..."		
		;;
		"$salir")
		echo "Hasta luego!"
		sleep 1
		clear
		exit
		;;
	esac
done
exit
