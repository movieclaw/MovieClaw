const test=require('node:test');const assert=require('node:assert/strict');
const fs=require('node:fs');const path=require('node:path');const vm=require('node:vm');
const context=vm.createContext({window:{}});
vm.runInContext(fs.readFileSync(path.join(__dirname,'../ui/desktop/subtitles.js'),'utf8'),context);
const subtitles=context.window.DesktopSubtitles;
test('mixed external and embedded subtitle refs preserve server indexes and unaddressable files are omitted',()=>{
 const tracks=subtitles.tracks({audio_streams:[{language:'eng',codec:'aac'}],subtitle_streams:[{external:true,file_name:'film.eng.srt'},{language:'zho',codec:'ass'},{external:true}]});
 assert.deepEqual(Array.from(tracks.subtitles,track=>track.ref),['external:film.eng.srt','embedded:1']);
 assert.equal(tracks.audio[0].ref,'embedded:0');
});
test('AI tracks are marked from generated filenames and system cancellation offers no useless retry',()=>{
 assert.equal(subtitles.aiSubtitle({file_name:'film.ai.chs.srt'}),true);
 assert.equal(subtitles.aiSubtitle({file_name:'ordinary.srt'}),false);
 assert.equal(subtitles.retryable({status:'cancelled',cancel_requested_by:'system:removed'}),false);
 assert.equal(subtitles.retryable({status:'failed'}),true);
});
