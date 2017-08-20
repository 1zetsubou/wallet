# PascalLite: P2P Cryptocurrency without need of historical operations

PascalLite is a P2P Cryptocurrency with human-friendly account numbers (addresses) and without need of keeping historical opeartions, blockchain can be safely removed without any harm to users accounts and balances.  
To start using it download precompiled Wallet application from `Releases` section or compile it from source code.  
Exchanges, processing systems, online shops can use console linux Daemon to control accounts, send and receive payments.  

# Compiling PascalLite from Source

## Wallet (Windows/Ubuntu)

1. Install Lazarus IDE 
2. Open `PascalLiteWallet.lpi`
3. Run -> Compile (CTRL + F9)

## Daemon (Linux)

## Compilation steps

1. Retrieve new lists of packages and install `gcc` and `make`

  ```bash
sudo apt-get update
sudo apt-get install make gcc
  ```

2. Build `Free Pascal Compiler`

  Download FPC source code version appropriate to your platform (ex.: `fpc-3.0.2.x86_64-linux.tar`) from [https://sourceforge.net/projects/freepascal/files/Linux/3.0.2/](https://sourceforge.net/projects/freepascal/files/Linux/3.0.2/)
  ```bash
tar -xvf fpc-3.0.2.x86_64-linux.tar  
cd fpc-3.0.2.x86_64-linux  
./install.sh
  ```
3. Build `OpenSSL`

  Download latest available OpenSSL 1.1.x source code [https://www.openssl.org/source/](https://www.openssl.org/source/)  (ex.: `openssl-1.1.0e.tar.gz`)

  ```bash
tar -xvf openssl-1.1.0e.tar.gz   
cd openssl-1.1.0e.tar.gz   
./config shared --prefix=$(pwd)/output   
make install
  ```

4. Install `lazarus` package

  ```bash
sudo apt-get install lazarus
  ```
  Under Ubuntu you'll need to install `fp-units-fcl` package
  ```bash
sudo apt-get install fp-units-fcl
  ```

5. Get latest release at [https://github.com/PascalLite/wallet/releases](https://github.com/PascalLite/wallet/releases) or checkout bleeding edge development version of PascalLite's `master`
  ```bash
  git clone https://github.com/PascalLite/wallet
  ```
6. Change to the root of the source code directory, copy `libcrypto.so.1.1` from step 3, build PascalLite daemon

  ```bash
cd wallet  
cp <OPENSSL_FOLDER>/output/lib/libcrypto.so.1.1 .  
fpc -FuUnits/PascalCoin/ -FuSynapse/lib/ -FuUnits/Utils/ pascallited.pp
  ```
7. Run PascalLite daemon in background

  ```bash
nohup ./pascallited -r &
  ```
8. Configure daemon settings in `~/PascalLite/pascallite.ini`

# RPC API

RPC control port is binded to 127.0.0.1:4003 by default. It serves [HTTP JSON-RPC](http://json-rpc.org/wiki/specification) requests.  
For detailed API description with examples read our [API JSON-RPC documentation](https://github.com/PascalLite/wallet/blob/master/doc/api_json-rpc.md).

# License
 
Distributed under the MIT software license, see the accompanying file LICENSE or visit http://www.opensource.org/licenses/mit-license.php.  

This product includes software developed by the OpenSSL Project and Denis Grinyuk [https://github.com/Arvur/OpenSSL-Delphi](https://github.com/Arvur/OpenSSL-Delphi), and some cryptographic functions inspirated in code written by Ladar Levison and Marco Ferrante.  

Starting point for the project was PascalCoin source code originally written by Albert Molina and available at [https://github.com/PascalCoin/PascalCoin](https://github.com/PascalCoin/PascalCoin)

# Supporting the Project

Donations can be sent directly to PascalLite development account: `0-10`
