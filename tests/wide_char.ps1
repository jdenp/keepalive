# prints one wide character and holds the pane open for the width test
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::Write([char]0x4E2D)
Start-Sleep -Seconds 30
