# apk-disassembler

Disassemble the apk by extracting the .apk, converting the binary xmls to plain text xml and converting .dex to .class and disassemble the .class(s) to .java.

This supports multiple apks and output the apk's signature, etc. and also ```app-analyzer.rb" can output the summary.


# how to use

Note that please ensure the dependent components first.

## Extract everything

```
$ ruby apk-disassembler.rb -o ~/tmp/apk -x ~/work/android/out/target/product/generic_x86_64
```

## Output summarize report

After the extraction,

```
$ ruby app-analyzer.rb ~/tmp/apk
```


# setup the dependent components

## AXMLPrinter2.jar

```
$ wget https://storage.googleapis.com/google-code-archive-downloads/v2/code.google.com/android4me/AXMLPrinter2.jar
```

You should symlink the built result to e.g. ~/bin.

```.zprofile
export PATH_AXMLPRINTER=~/bin/AXMLPrinter2.jar
```

## list-apk-signature

```
% cd ~/work
% git clone https://github.com/hidenorly/list-apk-signature
```

You should symlink the built result to e.g. ~/bin.


## Setup your preferred java disassembler

### jadx (recommended as of 2023)

https://github.com/skylot/jadx

```
$ git clone https://github.com/skylot/jadx.git
$ cd jadx
$ ./gradlew dist
```

```.zprofile
PATH_JAVADISASM=~/work/jadx/build/jadx/bin/jadx
```



### dex2jar for jad or jd-cli

```
$ cd ~/work
$ git clone https://github.com/pxb1988/dex2jar.git
$ cd dex2jar
$ gradle clean distZip
```

You may need to clone from my forked git (https://github.com/hidenorly/dex2jar) if you need to use newer version of gradle.

You should symlink the built result to e.g. ~/bin.
And you should set the environment variable for it.


### jad (you might be difficult to get)

Download jad and set the env.

```.zprofile
export PATH_JAVADISASM=~/bin/jad
```

Or use following:

### jd-cli

#### jd-core (Dependent module of jd-cli)

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

#### jd-cli

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


# Example Usages

## Extract specified abi's .so and exported symbols : e.g. arm64-v8a

```
% ruby apk-disassembler.rb sample.apk -a arm64-v8a -l -o tmp
```


# Todo:

* [x] Add jadx support
* [] Add summalizer (reporter) for apk-disassembler result
* [] Add lib/lib64 -> abi supported list & the filter
* [] Add lib list & the filter for such as gstreamer detection...

