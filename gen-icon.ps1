param([string]$Out = (Join-Path $PSScriptRoot 'app.ico'), [string]$Preview = "$env:TEMP\ar-icon-preview.png")
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$xaml = @'
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Width="256" Height="256" CornerRadius="54">
  <Border.Background>
    <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
      <GradientStop Offset="0" Color="#232C3D"/><GradientStop Offset="1" Color="#0A0C12"/>
    </LinearGradientBrush>
  </Border.Background>
  <Canvas Width="256" Height="256">
    <!-- open white book: two pages meeting at a center spine -->
    <Path Fill="#F5F7FA" Data="M124,86 C104,74 76,72 54,78 C50,79 48,82 48,86 L48,176 C48,180 51,183 55,182 C76,177 104,178 124,190 Z"/>
    <Path Fill="#FFFFFF" Data="M132,86 C152,74 180,72 202,78 C206,79 208,82 208,86 L208,176 C208,180 205,183 201,182 C180,177 152,178 132,190 Z"/>
    <Rectangle Canvas.Left="124" Canvas.Top="86" Width="8" Height="104" Fill="#C9CFDA"/>
  </Canvas>
</Border>
'@

function Render-Png([int]$s) {
    $design = [Windows.Markup.XamlReader]::Parse($xaml)
    $vb = New-Object System.Windows.Controls.Viewbox
    $vb.Stretch = [System.Windows.Media.Stretch]::Uniform; $vb.Width = $s; $vb.Height = $s; $vb.Child = $design
    $vb.Measure([System.Windows.Size]::new($s, $s)); $vb.Arrange([System.Windows.Rect]::new(0, 0, $s, $s)); $vb.UpdateLayout()
    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($s, $s, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($vb)
    $penc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $penc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $ms = New-Object System.IO.MemoryStream; $penc.Save($ms); $b = $ms.ToArray(); $ms.Close()
    return , $b
}

$sizes = 16, 20, 24, 32, 40, 48, 64, 128, 256
$frames = foreach ($s in $sizes) { Render-Png $s }

$io = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($io)
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($k = 0; $k -lt $sizes.Count; $k++) {
    $s = $sizes[$k]; $len = $frames[$k].Length
    $wb = if ($s -ge 256) { [byte]0 } else { [byte]$s }
    $bw.Write($wb); $bw.Write($wb); $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]$len); $bw.Write([uint32]$offset)
    $offset += $len
}
foreach ($f in $frames) { $bw.Write($f) }
$bw.Flush()
[System.IO.File]::WriteAllBytes($Out, $io.ToArray()); $io.Close()
[System.IO.File]::WriteAllBytes($Preview, $frames[$sizes.Count - 1])
"ICO written: $Out ($((Get-Item $Out).Length) bytes, $($sizes.Count) sizes)"
