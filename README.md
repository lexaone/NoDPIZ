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
После удаления отладочной информации бинарник занимает около 68 Kb для MacOsX arm64 , 61kb для Intel Linux и 55kb  для arm32 linux !

|OS|CPU|размер исполняемого файла|средний размер занятой памяти(RAM) при открытии страницы youtube.com|
|-|-|-|-|
|Linux|arm32|55Kb||
|Linux|X86_64|61Kb||
|MacOsX|aarch64|68Kb|3.2Mb|
|MocOsX|aarch64(python nodpi.py)|5Gb|15Mb|
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

**Предупреждение**: В коде есть особенность, связанная с повторным освобождением дескрипторов сетевого соединения.
В результате собранный в zig бинарник с опцией оптимизации Debug или ReleaseSafe очень быстро паникует.
Данная особенность игнорируется если программа скомпилирована с опциями оптимизации ReleaseSmall или ReleaseSafe.
Соответственно в build.zig выставлено ReleaseSmall по умолчанию.

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

В программе ради упрощения никак не контролируется список хостов при обращении к которым работает фрагментация.
Все обращения через nodpiz по https преобразовываются без разбора.
Возможно, в будущем я добавлю опцию, чтобы загружать список хостов, которые следует менять, но над данном этапе меня это полностью устраивает.
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

**Предупреждение**: Программа написана для образовательных целей. 
Вы можете использовать эту программу как есть или менять ее  на свое усмотрение. 
Автор не несет какой либо ответственности за ее использование или проблемы связанные с ее использованием.

**Warning**: This program was written for educational purposes. 
You can use this program as is or modify it  at your discretion. 
The author is not responsible for its use or any problems associated with its use.
