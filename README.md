# apk-disassembler

Disassemble the apk by extracting the .apk, converting the binary xmls to plain text xml and converting .dex to .class and disassemble the .class(s) to .java.

This supports multiple apks and output the apk's signature, etc.

# setup the dependent components

## AXMLPrinter2.jar

```
$ wget https://storage.googleapis.com/google-code-archive-downloads/v2/code.google.com/android4me/AXMLPrinter2.jar
```

You should symlink the built result to e.g. ~/bin.


## dex2jar

```
$ cd ~/work
$ git clone https://github.com/pxb1988/dex2jar.git
$ cd dex2jar
$ gradle clean distZip
```

You may need to clone from my forked git (https://github.com/hidenorly/dex2jar) if you need to use newer version of gradle.

You should symlink the built result to e.g. ~/bin.
And you should set the environment variable for it.

```.zprofile
export PATH_AXMLPRINTER=~/bin/AXMLPrinter2.jar
```

## jad or jd-core + jd-cli

Download jad and set the env.

```.zprofile
export PATH_JAVADISASM=~/bin/jad
```

Or use following:

### jd-core

```
% cd ~/work
% git clone https://github.com/java-decompiler/jd-core
% cd jd-core
% gradle build
```

You may need to clone from my forked git (https://github.com/hidenorly/jd-core.git) if you need to use newer version of gradle.

You should set the environment.

```.zprofile
export JD_CORE_PATH=~/work/jd-core/build/libs/jd-core-1.1.4.jar
```

### jd-cli

```
% cd ~/work
% git clone https://github.com/hidenorly/jd-cli.git
% cd jd-cli
% ./build.sh
```

You should symlink the built result to e.g. ~/bin.

You should set the environment.
```.zprofile
export PATH_JAVADISASM=~/bin/class2java.sh
```

## list-apk-signature

```
% cd ~/work
% git clone https://github.com/hidenorly/list-apk-signature
```

You should symlink the built result to e.g. ~/bin.



# Example Usages

## Extract specified abi's .so and exported symbols : e.g. arm64-v8a

```
% ruby apk-disassembler.rb sample.apk -a arm64-v8a -l -o tmp
```
