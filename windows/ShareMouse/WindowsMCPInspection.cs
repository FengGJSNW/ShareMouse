using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using System.Windows.Automation;
using ShareMouse.Network;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;
using Windows.Storage.Streams;

namespace ShareMouse;

// Unresponsive accessibility providers run in one bounded, disposable helper process.
internal static class WindowsMCPInspection {
    private static string Root=>Path.Combine(Path.GetTempPath(),"ShareMouse-MCP-Inspect");
    public static async Task<JsonObject> Inspect(byte[]? png,JsonNode options,JsonNode bounds,int width,int height,string? windowID,Func<bool> active){
        var folder=Path.Combine(Root,Guid.NewGuid().ToString("N"));Directory.CreateDirectory(folder);Process? child=null;
        try {
            if(png is not null)File.WriteAllBytes(Path.Combine(folder,"frame.png"),png);var request=Path.Combine(folder,"request.json");var output=Path.Combine(folder,"result.json");
            File.WriteAllText(request,ComputerUseService.Obj(("options",options),("desktop_bounds",bounds),("width",width),("height",height),("window_id",windowID)).ToJsonString());
            var start=new ProcessStartInfo(Environment.ProcessPath!){UseShellExecute=false,CreateNoWindow=true,WorkingDirectory=AppContext.BaseDirectory};start.ArgumentList.Add("--mcp-inspect");start.ArgumentList.Add(request);child=Process.Start(start)??throw new IOException("inspection_start_failed");
            var clock=Stopwatch.StartNew();while(!child.HasExited){if(!active()){child.Kill(true);throw new IOException("capture_interrupted");}child.Refresh();if(clock.ElapsedMilliseconds>4000||child.PrivateMemorySize64>512L*1024*1024){child.Kill(true);return ComputerUseService.Obj(("status","timeout"),("ocr",ComputerUseService.Obj(("status","inspection_timeout"))),("controls",ComputerUseService.Obj(("status","inspection_timeout"))));}await Task.Delay(50);}
            if(!File.Exists(output)||new FileInfo(output).Length>1024*1024)return ComputerUseService.Obj(("status","unavailable"));
            return JsonNode.Parse(File.ReadAllText(output)) as JsonObject??ComputerUseService.Obj(("status","unavailable"));
        } finally {if(child is not null){if(!child.HasExited){child.Kill(true);await child.WaitForExitAsync();}child.Dispose();}try{Directory.Delete(folder,true);}catch(IOException){}catch(UnauthorizedAccessException){}}
    }
    public static async Task Run(string request){
        var path=Path.GetFullPath(request);if(!path.StartsWith(Path.GetFullPath(Root)+Path.DirectorySeparatorChar,StringComparison.OrdinalIgnoreCase)||Path.GetFileName(path)!="request.json")return;
        var folder=Path.GetDirectoryName(path)!;var result=new JsonObject();
        try {
            var data=JsonNode.Parse(File.ReadAllText(path))!;var options=data["options"]!;ComputerUseService.ValidateObservationOptions(options);
            if(ComputerUseService.Flag(options,"include_ocr"))result["ocr"]=await Recognize(File.ReadAllBytes(Path.Combine(folder,"frame.png")),options);
            if(ComputerUseService.Flag(options,"include_controls")||ComputerUseService.Flag(options,"text_only"))result["controls"]=Controls(data,options);
        } catch(Exception){result["status"]="unavailable";}
        File.WriteAllText(Path.Combine(folder,"result.json"),result.ToJsonString());
    }
    private static async Task<JsonObject> Recognize(byte[] png,JsonNode options){
        try {
            var language=options["ocr_language"]?.GetValue<string>();var engine=language is null?OcrEngine.TryCreateFromUserProfileLanguages():OcrEngine.TryCreateFromLanguage(new Windows.Globalization.Language(language));
            if(engine is null)return ComputerUseService.Obj(("status","language_unavailable"),("engine","windows_ocr"));
            using var stream=new InMemoryRandomAccessStream();using(var writer=new DataWriter(stream)){writer.WriteBytes(png);await writer.StoreAsync();writer.DetachStream();}stream.Seek(0);
            var decoder=await BitmapDecoder.CreateAsync(stream);var crop=Region(options["ocr_region"],(int)decoder.PixelWidth,(int)decoder.PixelHeight);
            var transform=new BitmapTransform {Bounds=new BitmapBounds {X=(uint)crop.X,Y=(uint)crop.Y,Width=(uint)crop.Width,Height=(uint)crop.Height}};
            using var bitmap=await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8,BitmapAlphaMode.Premultiplied,transform,ExifOrientationMode.IgnoreExifOrientation,ColorManagementMode.DoNotColorManage);
            if(bitmap.PixelWidth>OcrEngine.MaxImageDimension||bitmap.PixelHeight>OcrEngine.MaxImageDimension)return ComputerUseService.Obj(("status","image_size_unsupported"));
            var result=await engine.RecognizeAsync(bitmap);var items=new JsonArray();var limit=ComputerUseService.Integer(options,"max_ocr_results",100,1,200);
            foreach(var word in result.Lines.SelectMany(line=>line.Words)){var r=word.BoundingRect;if(items.Count>=limit)break;items.Add(ComputerUseService.Obj(("text",word.Text),("confidence",null),("bounds",ComputerUseService.Obj(("x",r.X+crop.X),("y",r.Y+crop.Y),("width",r.Width),("height",r.Height))),("coordinate_space","screenshot_pixels")));}
            return ComputerUseService.Obj(("status","available"),("engine","windows_ocr"),("language",engine.RecognizerLanguage.LanguageTag),("items",items),("text_angle",result.TextAngle),("confidence_available",false),("text_does_not_prove_clickability",true));
        }catch(Exception){return ComputerUseService.Obj(("status","unavailable"),("engine","windows_ocr"),("error","recognition_failed_or_language_unavailable"));}
    }
    internal static System.Drawing.RectangleF Region(JsonNode? node,int width,int height){if(node is null)return new(0,0,width,height);var r=new System.Drawing.RectangleF((float)node["x"]!.GetValue<double>(),(float)node["y"]!.GetValue<double>(),(float)node["width"]!.GetValue<double>(),(float)node["height"]!.GetValue<double>());if(r.X<0||r.Y<0||r.Width<=0||r.Height<=0||r.Right>width||r.Bottom>height)throw new IOException("analysis_region_outside_observation");return r;}
    private static JsonObject Controls(JsonNode data,JsonNode options){
        var started=Stopwatch.StartNew();var hwnd=GetForegroundWindow();GetWindowThreadProcessId(hwnd,out var pid);var windowID="win:"+pid+":"+hwnd.ToInt64().ToString("X");
        if(data["window_id"]?.GetValue<string>()!=windowID)return ComputerUseService.Obj(("status","window_changed_during_inspection"));
        var bounds=data["desktop_bounds"]!;var left=bounds["x"]!.GetValue<double>();var top=bounds["y"]!.GetValue<double>();var dx=bounds["width"]!.GetValue<double>();var dy=bounds["height"]!.GetValue<double>();var width=data["width"]!.GetValue<int>();var height=data["height"]!.GetValue<int>();var limit=ComputerUseService.Integer(options,"max_controls",50,1,100);
        JsonObject? Item(AutomationElement element){var current=element.Current;var rect=current.BoundingRectangle;if(current.IsOffscreen||rect.IsEmpty||rect.Width<=0||rect.Height<=0||rect.Right<=left||rect.Left>=left+dx||rect.Bottom<=top||rect.Top>=top+dy)return null;
            var item=ComputerUseService.Obj(("name",current.Name),("role",current.ControlType.ProgrammaticName),("automation_id",current.AutomationId),("enabled",current.IsEnabled),("bounds",ComputerUseService.Obj(("x",(rect.X-left)/dx*width),("y",(rect.Y-top)/dy*height),("width",rect.Width/dx*width),("height",rect.Height/dy*height))),("coordinate_space","screenshot_pixels"),("source","windows_ui_automation"));
            if(current.IsPassword){item["value_redacted"]=true;item["name"]="[protected field]";}
            else if(element.TryGetCurrentPattern(ValuePattern.Pattern,out var value))item["value"]=new string(((ValuePattern)value).Current.Value.Take(512).ToArray());
            else if(element.TryGetCurrentPattern(TextPattern.Pattern,out var text))item["text"]=((TextPattern)text).DocumentRange.GetText(1024);
            return item;}
        var found=new JsonArray();var tree=new JsonArray();var queue=new Queue<(AutomationElement element,int? parent,int depth)>();queue.Enqueue((AutomationElement.FromHandle(hwnd),null,0));var visited=0;var walker=TreeWalker.ControlViewWalker;
        while(queue.Count>0&&visited<200&&tree.Count<limit&&started.ElapsedMilliseconds<1500){var (element,parent,depth)=queue.Dequeue();visited++;try{var type=element.Current.ControlType;
            if(Item(element)is {} item){var index=tree.Count;item["node_id"]=index;item["parent_id"]=parent;item["depth"]=depth;tree.Add(item);parent=index;if(type!=ControlType.Window&&type!=ControlType.Pane&&type!=ControlType.Group)found.Add(item.DeepClone());}
            for(var child=walker.GetFirstChild(element);child is not null&&queue.Count+visited<200;child=walker.GetNextSibling(child))queue.Enqueue((child,parent,depth+1));}catch(ElementNotAvailableException){}catch(InvalidOperationException){}}
        var result=ComputerUseService.Obj(("status",found.Count==0?"no_semantic_controls":"available"),("items",found),("tree",tree),("truncated",queue.Count>0),("elapsed_ms",started.Elapsed.TotalMilliseconds),("occlusion_guarantee",false));
        if(options["control_point"]is {} point){var x=point["x"]!.GetValue<double>();var y=point["y"]!.GetValue<double>();if(x<0||y<0||x>=width||y>=height)throw new IOException("control_point_outside_observation");try{var element=AutomationElement.FromPoint(new System.Windows.Point(left+x/width*dx,top+y/height*dy));result["element_at_point"]=Item(element);result["point_window_owner_matches_foreground"]=element.Current.ProcessId==pid;}catch(ElementNotAvailableException){result["element_at_point"]=null;}}
        if(GetForegroundWindow()!=hwnd)return ComputerUseService.Obj(("status","window_changed_during_inspection"));return result;
    }
    [DllImport("user32.dll")]private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]private static extern uint GetWindowThreadProcessId(IntPtr window,out uint processId);
}
