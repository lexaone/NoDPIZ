# NoDPIZ
Tiny proxy written in zig. Uses simple SSL fragmentation to avoid DPI. 
No system privileges needed.

It works on Linux and Macos
inspired by https://github.com/theo0x0/nodpi

### Russian: 
Простой и маленький proxy, написанный на Zig. Использует метод фрагментации SSL для обхода
DPI.  Написан по мотивам https://github.com/theo0x0/nodpi
Работа и сборка проверены на Linux и MacOSX.
Мне очень нравятся компактные программы, которые не требуют [развесистых интерпретаторов](https://python.org) 
и занимают мало места на файловой системе и RAM. 
После удаления отладочной информации бинарник занимает около 100 Kb для MacOsX arm64 , 88kb для Intel Linux и 81kb  для arm32 linux !

Для сравнения приведены данные по рантайму прокси на python в Linuх и macos

|OS|CPU|размер исполняемого файла|средний размер занятой памяти(RAM) при открытии страницы youtube.com|
|-|-|-|-|
|Linux|arm32|81Kb||
|Linux|X86_64|88Kb||
|MacOsX|aarch64|101Kb|3.2Mb|
|MacOsX|aarch64(python nodpi.py)|5Gb|15Mb|
|linux|aarch64(python nodpi.py)|100-200 Mb|20-30Mb|

### Сборка: 

```bash
git clone https://github.com/lexaone/NoDPIZ
cd NoDPIZ
zig build 
strip zig-out/bin/nodpiz
cp zig-out/bin/nodpiz <place for executable files>
```

**Замечание**: Программа без проблем собирается и работает с zig из master ветки. На текущий момент это 0.15.0-dev.703+597dd328e

**Предупреждение**: В build.zig указано что бинарник собирается с оптимизацией ReleaseSmall по умолчанию.
Если потребуется что-то другое (ReleaseSafe,ReleaseFast,Debug),то явно укажите это из коммандной строки:
```
zig build -Doptimize=ReleaseSafe
```

Если нужно собрать бинарник под другую платформу можно это указать:
```
zig build -Dtarget=arm-linux
```

### Использование:
Просто запустить скомпилированный исполняемый файл. nodpiz вешается на 127.0.0.1 интерфейсе и на порту 8881
При обращении к порту 8881 как к https прокси происходит попытка обхода DPI путем фрагментаци tcp пакетов SSL.

Поскольку я использую MacOsX на своей рабочей машине, опишу автоматический способ запуска программы:
- копируете готовый конфигурационный файл для launchctl (демон ответственный за работу сервисов в MacOsX, 
  чем-то похож на systemd) из artifacts/lexaone.nodpiz.local.plist в ~/Library/LaunchAgents/
- редактируете скопированный файл под свои нужды. В основном нужно поменять путь до установленного исполняемого файла nodpiz
- запускаете proxy командой 
  
  > launchctl load ~/Library/LaunchAgents/lexaone.nodpiz.local.plist
 
- убеждаетесь сервис lexaone.nodpiz.local стартовал:

  >launchctl list lexaone.nodpiz.local

```
  {
        "LimitLoadToSessionType" = "Aqua";
        "Label" = "lexaone.nodpiz.local";
        "OnDemand" = false;
        "LastExitStatus" = 15;
        "PID" = 24713;
        "Program" = "/Users/lexa/bin/nodpiz";
        "ProgramArguments" = (
            "/Users/lexa/bin/nodpiz";
        );
};
```

По номеру PID можно посмотреть, в работе ли сервис.


В программе по умолчанию и ради упрощения никак не контролируется список хостов при обращении к которым работает фрагментация.
Все обращения через nodpiz по https преобразовываются без разбора.
Дело в том, что я использую локальную версию [privoxy](https://www.privoxy.org/) и все списки хостов веду в его конфигурационных файлах.
Например для доступа к yotube я добавил следующие правила в конфигурацию privoxy:
```
        forward .youtube.com 127.0.0.1:8881
        forward .youtu.be 127.0.0.1:8881
        forward .yt.be 127.0.0.1:8881
        forward .googlevideo.com 127.0.0.1:8881
        forward .ytimg.com 127.0.0.1:8881
        forward .ggpht.com 127.0.0.1:8881
        forward .gvt1.com 127.0.0.1:8881
        forward .youtube-nocookie.com 127.0.0.1:8881
        forward .youtube-ui.l.google.com 127.0.0.1:8881
        forward .youtubeembeddedplayer.googleapis.com 127.0.0.1:8881
        forward .youtube.googleapis.com 127.0.0.1:8881
        forward .youtubei.googleapis.com 127.0.0.1:8881
        forward .yt-video-upload.l.google.com 127.0.0.1:8881
        forward .wide-youtube.l.google.com 127.0.0.1:8881
```
Cоответственно в моей системе настроен локальный privoxy в качестве качестве основного системного proxy и все обращения сначала идут через
него, а затем уже пробрасываются на другие proxy (например tor, nodpiz и т.д.)
Таким образом я не создаю новые сущности в конфигурации и все изменения веду централизовано.

В программе есть следующие опции:
```
NoDPIZ proxy

Usage: nodpiz [OPTIONS]

Options:
    -h, --help                                    Display help
    -v, --version                                 Display version
    -d, --debug                                   Print debug information
    -b, --blacklist=<BLACKLIST_FILE>              blacklist file with hosts to bypass,optional, default 
 is bypass to all hosts
    -p, --port=<TCP_PORT>                         Port Listening,optional, default is 8881
    -i, --iface=<IFACE>                           interface listening, ex: 127.0.0.1 or 0.0.0.0, optional,default is 127.0.0.1
    -h, --help                                    Print this help and exit

```

Опция `-b` используется для указания файла со списком хостов, для которых будет работать преобразование.
Остальные пакеты будут пробрасываться без изменения.
Опция `-p` указывает, на каком TCP порту прокси будет висеть прокси (по умолчанию 8881)
Опция `-i` указывает, на каком интерфейсе висеть прокси (по умолчанию 127.0.0.1, чтобы не давать доступ к этому прокси откуда угодно)


**Предупреждение**: Программа написана для образовательных целей. 
Вы можете использовать эту программу как есть или менять ее  на свое усмотрение. 

Автор не несет какой либо ответственности за ее использование или проблемы связанные с ее использованием.

**Warning**: This program was written for educational purposes. 
You can use this program as is or modify it  at your discretion. 
The author is not responsible for its use or any problems associated with its use.
